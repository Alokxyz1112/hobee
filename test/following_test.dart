import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/background.dart';
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

  Future<List<Map<String, dynamic>>> page(Follow f, {int? after, int? before, int limit = 100}) async {
    calls.add('${f.label} after=$after before=$before');
    if (failing.contains(f.label)) throw Exception('HTTP 500');
    final ts = (times[f.label] ?? const <int>[]).where((t) => (after == null || t > after) && (before == null || t < before)).toList()
      ..sort((a, b) => b.compareTo(a));
    return [
      for (final t in ts.take(limit < size ? limit : size))
        {
          'id': '${f.name}_$t', 'title': 't', 'subreddit': f.kind == FollowKind.sub ? f.name : 'any', 'author': f.kind == FollowKind.user ? f.name : 'a',
          'permalink': '/p', 'created_utc': t, 'url': 'https://i.redd.it/${f.name}$t.jpg', 'post_hint': 'image',
          'all_awardings': const [], 'retrieved_on': 1,
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
    await FollowStore.add(pid, parseFollowList('r/aa r/bb r/cc u/ddd').follows);
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
    Following.refreshSize = 3;
    Following.fillPages = 10;
    Following.minGap = Duration.zero;
    Following.maxGap = Duration.zero;
    Following.gap = Duration.zero;
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

  test('a failing entry is retried once at the end of the round, then counted', () async {
    Following.budget = 10;
    fake.failing.add('r/bb');
    await Following.fetchMore(src, now: t0);
    expect(fake.calls.where((c) => c.startsWith('r/bb')).length, 2);
    expect(followingStatus.value, contains('1 failed'));
    expect(await posts(), greaterThan(0));
  });

  test('refresh of an entry with posts asks for a small page of newer posts only', () async {
    Following.budget = 10;
    Following.refreshSize = 1;
    final sizes = <int>[];
    Following.fetchPage = (f, {after, before, limit = 100}) {
      if (after != null) sizes.add(limit);
      return fake.page(f, after: after, before: before, limit: limit);
    };
    await Following.fetchMore(src, now: t0);
    Following.debugReset();
    await Following.fetchMore(src, fromStart: true, now: t0.add(const Duration(hours: 1)));
    expect(sizes, isNotEmpty);
    expect(sizes.every((s) => s == 1), isTrue);
  });

  test('posts are saved without the archive fields the app never reads', () async {
    Following.budget = 10;
    await Following.fetchMore(src, now: t0);
    final ps = await Db.load(src);
    expect(ps, isNotEmpty);
    expect(ps.every((p) => !p.raw.containsKey('all_awardings') && !p.raw.containsKey('retrieved_on')), isTrue);
    expect(ps.every((p) => p.media.isNotEmpty), isTrue);
  });

  test('empty profile says so and is done', () async {
    final empty = await FollowStore.createProfile('Empty');
    expect(await Following.fetchMore(followingKey(empty), now: t0), -1);
    expect(followingStatus.value, contains('no subreddits or users'));
  });

  test('adaptive gap: doubles after a slow-down, eases back after successes, within limits', () {
    final (minG, maxG) = (Following.minGap, Following.maxGap);
    Following.minGap = const Duration(seconds: 3);
    Following.maxGap = const Duration(seconds: 15);
    var g = const Duration(seconds: 3);
    g = Following.nextGap(g, busy: true);
    expect(g.inSeconds, 6);
    g = Following.nextGap(Following.nextGap(g, busy: true), busy: true);
    expect(g.inSeconds, 15, reason: 'capped');
    for (var i = 0; i < 20; i++) {
      g = Following.nextGap(g, busy: false);
    }
    expect(g.inSeconds, 3, reason: 'back to the minimum');
    Following.minGap = minG;
    Following.maxGap = maxG;
  });

  test('chips: posts in followed subreddits vs posts by followed users', () async {
    Following.budget = 10;
    await Following.fetchMore(src, now: t0);
    final all = await Db.load(src);
    followingKind.value = 1;
    expect(Following.applyKind(all, src).every((p) => ['aa', 'bb', 'cc'].contains(p.subreddit)), isTrue);
    followingKind.value = 2;
    final users = Following.applyKind(all, src);
    expect(users, isNotEmpty);
    expect(users.every((p) => p.author == 'ddd'), isTrue);
    followingKind.value = 0;
    expect(Following.applyKind(all, src).length, all.length);
  });

  group('fill-back window', () {
    final now = t0.millisecondsSinceEpoch ~/ 1000;
    int daysAgo(int d) => now - d * 86400;

    test('a round preloads 2 months of subreddits and 6 months of users, newest gap first; older on scroll', () async {
      Following.budget = 10;
      fake.times
        ..['r/aa'] = [for (final d in [1, 10, 30, 50, 70, 90, 110, 130]) daysAgo(d)]
        ..['r/bb'] = []
        ..['u/ddd'] = [for (final d in [1, 100, 150, 170, 200, 300, 400]) daysAgo(d)];
      await Following.fetchMore(src, now: t0);
      // After the newest pages: aa reaches back 30 days (window 60), ddd 150 days (window 180).
      // aa's gap starts later (newer), so it goes first; one page each reaches past the window.
      expect(fake.calls.skip(4), ['r/aa after=null before=${daysAgo(30)}', 'u/ddd after=null before=${daysAgo(150)}']);
      expect(Following.refreshing(src), isFalse, reason: 'both reach their window');
      expect(followingStatus.value, contains('scroll for older posts'));
      expect(await posts(), 6 + 6);

      // Scrolling to the end pages back past the window.
      fake.calls.clear();
      await Following.fetchMore(src, now: t0);
      expect(fake.calls, ['r/aa after=null before=${daysAgo(90)}', 'u/ddd after=null before=${daysAgo(300)}']);
      expect(await posts(), 8 + 7);
    });

    test('fill-back stops at the page cap for a busy subreddit; the refresher runs it on its own', () async {
      Following.budget = 1;
      Following.fillPages = 2;
      fake.times
        ..['r/aa'] = [for (var d = 1; d <= 50; d++) daysAgo(d)]
        ..['r/bb'] = []
        ..['u/ddd'] = [];
      FollowingRefresher.start(src);
      for (var i = 0; i < 100 && (FollowingRefresher.running(src) || followingStatus.value == null); i++) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      expect(FollowingRefresher.running(src), isFalse);
      expect(fake.calls.where((c) => c.startsWith('r/aa')).length, 1 + 2, reason: 'newest page + 2 fill pages');
      expect(await posts(), 9);
      expect(Following.refreshing(src), isFalse);
      Following.fillPages = 10;
    });
  });

  test('the refresher runs the whole round on its own', () async {
    Following.budget = 1;
    FollowingRefresher.start(src);
    for (var i = 0; i < 50 && !(followingStatus.value ?? '').startsWith('All 4 checked'); i++) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(followingStatus.value, startsWith('All 4 checked'));
    expect(FollowingRefresher.running(src), isFalse);
  });

  test('a background run continues the active profile round until done', () async {
    Following.budget = 1;
    await FollowStore.setActive(pid);
    expect(await BackgroundRefresh.run(), isTrue);
    expect(followingStatus.value, startsWith('All 4 checked'));
    expect(await posts(), greaterThan(0));
  });
}
