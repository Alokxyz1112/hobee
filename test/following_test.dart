import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/following.dart';
import 'package:hobee/follows.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fake Arctic Shift: each entry has posts at fixed times; pages of [size], newest first.
class FakeArchive {
  final Map<String, List<int>> times; // follow key -> created_utc values
  final calls = <String>[];
  final failing = <String>{};
  int size = 3;
  FakeArchive(this.times);

  Future<List<Map<String, dynamic>>> page(Follow f, {int? after, int? before}) async {
    calls.add('${f.label} after=$after before=$before');
    if (failing.contains(f.label)) throw Exception('HTTP 500');
    final ts = (times[f.label] ?? const <int>[]).where((t) => (after == null || t > after) && (before == null || t < before)).toList()
      ..sort((a, b) => b.compareTo(a));
    return [
      for (final t in ts.take(size))
        {
          'id': '${f.name}_$t', 'title': 't', 'subreddit': f.kind == FollowKind.sub ? f.name : 'any', 'author': f.kind == FollowKind.user ? f.name : 'a',
          'permalink': '/p', 'created_utc': t, 'url': 'https://i.redd.it/${f.name}$t.jpg', 'post_hint': 'image',
        }
    ];
  }
}

void main() {
  late int pid;
  late String src;
  late FakeArchive fake;
  final t0 = DateTime.utc(2026, 11, 24, 12);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    final d = await Db.db;
    for (final t in ['follows', 'profiles', 'posts', 'cursors']) {
      await d.delete(t);
    }
    pid = await FollowStore.createProfile('Test');
    await FollowStore.add(pid, parseFollowList('r/aa r/bb r/cc u/dddd').follows);
    src = followingKey(pid);
    fake = FakeArchive({
      'r/aa': [100, 90, 80, 70, 60],
      'r/bb': [95, 85],
      'r/cc': [],
      'u/ddd': [99, 89, 79, 69],
    });
    Following.fetchPage = fake.page;
    Following.budget = 2;
    Following.pageSize = 3;
    Following.debugReset();
  });

  Future<int> posts() async => (await Db.load(src)).length;

  test('a refresh round goes through every entry in small batches, then pages back', () async {
    expect(await Following.fetchMore(src, now: t0), greaterThan(0));
    expect(fake.calls.length, 2, reason: 'budget of 2 requests per call');
    expect(followingStatus.value, startsWith('Checked 2 of 4'));
    await Following.fetchMore(src, now: t0);
    expect(fake.calls.length, 4);
    expect(followingStatus.value, startsWith('All 4 checked'));
    // newest 3 of aa, both of bb, none of cc, newest 3 of dd
    expect(await posts(), 3 + 2 + 0 + 3);

    // Paging back: only aa and dd have more; aa's oldest loaded post (80) is newer than dd's (79), so aa goes first.
    await Following.fetchMore(src, now: t0);
    expect(fake.calls.skip(4), ['r/aa after=null before=80', 'u/ddd after=null before=79']);
    expect(await posts(), 5 + 2 + 4);
    // Everything is loaded now.
    expect(await Following.fetchMore(src, now: t0), -1);
    expect((await Db.cursor(src)).$2, isTrue, reason: 'source marked done');
  });

  test('pull-to-refresh skips entries checked in the last 30 minutes, later asks only for newer posts', () async {
    Following.budget = 10;
    await Following.fetchMore(src, now: t0);
    fake.calls.clear();
    await Following.fetchMore(src, fromStart: true, now: t0.add(const Duration(minutes: 10)));
    expect(fake.calls, isEmpty, reason: 'nothing to refresh within 30 minutes, and everything older is already loaded');
    fake.calls.clear();
    fake.times['r/aa'] = [130, ...fake.times['r/aa']!];
    Following.debugReset();
    await Following.fetchMore(src, fromStart: true, now: t0.add(const Duration(minutes: 31)));
    expect(fake.calls, contains('r/aa after=100 before=null'));
    expect(fake.calls, contains('u/ddd after=99 before=null'));
    expect((await Db.load(src)).any((p) => p.id == 'aa_130'), isTrue);
  });

  test('a failing entry is counted and the round goes on', () async {
    Following.budget = 10;
    fake.failing.add('r/bb');
    await Following.fetchMore(src, now: t0);
    expect(followingStatus.value, contains('1 failed'));
    expect(await posts(), greaterThan(0));
  });

  test('empty profile says so and is done', () async {
    final empty = await FollowStore.createProfile('Empty');
    expect(await Following.fetchMore(followingKey(empty), now: t0), -1);
    expect(followingStatus.value, contains('no subreddits or users'));
  });
}
