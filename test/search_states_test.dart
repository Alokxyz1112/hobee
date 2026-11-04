import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/archive.dart';
import 'package:hobee/list_footer.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Widget host(Widget child, {double scale = 1, Brightness b = Brightness.light, Size size = const Size(320, 640)}) => MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale), padding: const EdgeInsets.only(top: 24, bottom: 34)),
      child: MaterialApp(theme: ThemeData(brightness: b), home: Scaffold(body: ListView(children: [child]))),
    );

void main() {
  Archive.pacing = false;
  ListFooter f({bool loading = false, bool done = false, bool empty = true, String? error, bool searching = true}) =>
      ListFooter(loading: loading, done: done, empty: empty, error: error, searching: searching, onMore: () {});

  testWidgets('empty list never shows a bare Load more', (t) async {
    await t.pumpWidget(host(f()));
    expect(find.text('Load more'), findsNothing);
    expect(find.text('Search older posts'), findsOneWidget);
    expect(find.textContaining('No matches'), findsOneWidget);
    await t.pumpWidget(host(f(searching: false)));
    expect(find.text('Load more'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('loading, error, done and more states', (t) async {
    await t.pumpWidget(host(f(loading: true)));
    expect(find.byKey(const Key('footer-loading')), findsOneWidget);
    expect(find.text('Searching posts...'), findsOneWidget);
    await t.pumpWidget(host(f(error: 'Network down')));
    expect(find.text('Network down'), findsOneWidget);
    expect(find.byKey(const Key('footer-retry')), findsOneWidget);
    await t.pumpWidget(host(f(done: true)));
    expect(find.text('Nothing here'), findsOneWidget);
    await t.pumpWidget(host(f(empty: false)));
    expect(find.text('Load more'), findsOneWidget);
  });

  testWidgets('retry calls back', (t) async {
    var n = 0;
    await t.pumpWidget(host(ListFooter(loading: false, done: false, empty: true, error: 'x', onMore: () => n++)));
    await t.tap(find.byKey(const Key('footer-retry')));
    expect(n, 1);
  });

  for (final b in Brightness.values) {
    testWidgets('no overflow at large font on a small screen ($b)', (t) async {
      for (final s in [f(), f(loading: true), f(error: 'Couldn\'t load more: busy (asked to slow down)'), f(empty: false)]) {
        await t.pumpWidget(host(s, scale: 2.0, b: b, size: const Size(280, 560)));
        expect(t.takeException(), isNull);
      }
    });
  }

  test('keyword search falls back to local matching at once when the archive times out', () async {
    Archive.resetKeywordState();
    final hits = <String>[];
    final client = MockClient((r) async {
      hits.add(r.url.query);
      if (r.url.queryParameters.containsKey('title')) return http.Response('{"error":"Timeout. Maybe slow down a bit"}', 422);
      return http.Response('{"data":[{"id":"a","title":"A cat photo","created_utc":100},{"id":"b","title":"dog","created_utc":90}]}', 200,
          headers: {'content-type': 'application/json'});
    });
    final rows = await http.runWithClient(() => Archive.subPage('pics', title: 'cat'), () => client);
    expect(rows.map((r) => r['id']), ['a']);
    expect(hits.where((q) => q.contains('title=')).length, 1, reason: 'no slow-down retries for keyword queries');
    // Second page skips the timed-out keyword query entirely.
    hits.clear();
    await http.runWithClient(() => Archive.subPage('pics', title: 'cat'), () => client);
    expect(hits.where((q) => q.contains('title=')), isEmpty);
    Archive.resetKeywordState();
  });
}
