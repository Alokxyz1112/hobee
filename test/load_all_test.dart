import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/archive.dart';
import 'package:hobee/archive_ui.dart';
import 'package:hobee/error_text.dart';
import 'package:hobee/load_all.dart';
import 'package:hobee/models.dart';

List<Post> fakePosts(int n) => [
      for (var i = 0; i < n; i++)
        Post.fromJson({
          'id': 'p$i', 'title': 'post $i', 'subreddit': 's', 'author': 'amy', 'created_utc': 1750000000 - i * 3600,
          'url': 'https://i.redd.it/x$i.jpg', 'post_hint': 'image',
        })!
    ];

void main() {
  test('loads 2,000 posts in sequential pages and finishes', () async {
    final db = <Post>[];
    var inFlight = 0, maxInFlight = 0, refreshes = 0, waits = 0;
    final all = fakePosts(2000);
    final r = LoadAllRunner(
      stopped: () => false,
      wait: (_) async => waits++,
      onRefresh: () async => refreshes++,
      fetch: () async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(Duration.zero);
        final next = all.skip(db.length).take(100).toList();
        db.addAll(next);
        inFlight--;
        return (added: next.length, done: db.length >= all.length);
      },
    );
    expect(await r.run(), LoadAllEnd.finished);
    expect(db.length, 2000);
    expect(maxInFlight, 1);
    expect(refreshes, lessThan(20), reason: 'the list is reloaded every few pages, not every page');
    expect(waits, greaterThan(0), reason: 'every page yields, so the UI keeps drawing');
  });

  test('Stop ends the run', () async {
    var pages = 0, stop = false;
    final r = LoadAllRunner(stopped: () => stop, wait: (_) async {}, fetch: () async {
      if (++pages == 5) stop = true;
      return (added: 100, done: false);
    });
    expect(await r.run(), LoadAllEnd.stopped);
    expect(pages, 5);
  });

  test('errors back off, then give up instead of looping forever', () async {
    final waits = <Duration>[];
    final r = LoadAllRunner(stopped: () => false, wait: (d) async => waits.add(d), fetch: () async => throw Exception('HTTP 422'));
    expect(await r.run(), LoadAllEnd.gaveUp);
    expect(waits, [const Duration(seconds: 5), const Duration(seconds: 10), const Duration(seconds: 20)]);
  });

  test('a source error in the middle is skipped and loading carries on', () async {
    var i = 0;
    final r = LoadAllRunner(stopped: () => false, wait: (_) async {}, fetch: () async {
      i++;
      if (i == 3) throw Exception('busy');
      return (added: 50, done: i >= 6);
    });
    expect(await r.run(), LoadAllEnd.finished);
  });

  test('pages that never add anything stop the run', () async {
    var n = 0;
    final r = LoadAllRunner(stopped: () => false, wait: (_) async {}, fetch: () async { n++; return (added: 0, done: false); });
    expect(await r.run(), LoadAllEnd.stalled);
    expect(n, 8);
  });

  test('page cap', () async {
    final r = LoadAllRunner(stopped: () => false, wait: (_) async {}, maxPages: 10, fetch: () async => (added: 1, done: false));
    expect(await r.run(), LoadAllEnd.limit);
  });

  testWidgets('status panel with 2,000 posts shows progress and Stop', (t) async {
    final posts = fakePosts(2000);
    archiveStatus.value = [
      const ProviderStatus(ArchiveProvider.arcticShift, count: 176),
      const ProviderStatus(null, name: 'Reddit JSON', error: 'blocked', detail: 'HTTP 403 from https://www.reddit.com/u.json\n<body class=theme-beta><div><style>.x{}'),
    ];
    var stops = 0;
    Widget panel(bool bulk) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DeepStatusPanel(
        all: posts, bulk: bulk, done: false, bulkPages: 7, bulkAdded: 650, oldest: '', onRetry: () {}, onFetchAll: () {},
        onCancel: () => stops++, onShowText: () {}))));
    await t.pumpWidget(panel(false));
    expect(find.byKey(const Key('load-all')), findsOneWidget, reason: 'Load all is offered while one source works');
    await t.pumpWidget(panel(true));
    expect(find.textContaining('Loading all: 2000 posts, 7 pages (+650)'), findsOneWidget);
    await t.tap(find.byKey(const Key('load-all-stop')));
    expect(stops, 1);
    archiveStatus.value = [];
  });

  test('technical details are short and readable', () {
    final d = detailLine('Reddit JSON', 'HTTP 403 from https://www.reddit.com/user/x/submitted.json?limit=100\n<body class=theme-beta><div><style>.theme-light{--rem360:22.5rem}');
    expect(d, 'Reddit JSON: HTTP 403 from https://www.reddit.com/user/x/submitted.json?limit=100');
    expect(bodySnippet('<!DOCTYPE html><html>blocked</html>'), '');
    final rss = cleanDetail('Reddit asked to wait; skipping RSS until 2026-11-04 09:52:25.137153');
    expect(rss, 'Reddit asked to wait; skipping RSS until 9:52 AM');
    expect(shortTime(DateTime(2026, 1, 1, 0, 5)), '12:05 AM');
    expect(shortTime(DateTime(2026, 1, 1, 13, 0)), '1:00 PM');
    expect(detailLine('Redlib', '  a.com: unavailable (HTTP 404)\n   b.com: bot check page'), 'Redlib:\na.com: unavailable (HTTP 404)\nb.com: bot check page');
  });
}
