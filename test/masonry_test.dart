import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/masonry.dart';

void main() {
  test('tileAspect clamps extremes and falls back to square', () {
    expect(tileAspect(null), 1);
    expect(tileAspect(0.1), minTileAspect);
    expect(tileAspect(10), maxTileAspect);
    expect(tileAspect(0.75), 0.75);
    expect(tileAspect(0.75, square: true), 1);
    expect(tileAspect(double.nan), 1);
  });

  test('square tiles fill row by row like a fixed grid', () {
    final m = Masonry(List.filled(7, 1.0), 3, 300);
    expect(m.columns, [
      [0, 3, 6],
      [1, 4],
      [2, 5],
    ]);
    expect(m.top, [0, 0, 0, 100, 100, 100, 200]);
    expect(m.extent, 300); // ceil(7 / 3) rows of 100
  });

  test('each item goes to the shortest column', () {
    // Column width 100: heights 200 (tall), 50 (wide), 100 (square).
    final m = Masonry([0.5, 2.0, 1.0, 1.0, 1.0], 3, 300);
    // After the first row: col0=200, col1=50, col2=100 → item 3 to col1 (50→150),
    // then col1=150 vs col2=100 → item 4 to col2.
    expect(m.columns, [
      [0],
      [1, 3],
      [2, 4],
    ]);
    expect(m.top[3], 50);
    expect(m.top[4], 100);
    expect(m.extent, 200);
  });

  test('sectionTops and sectionOffset include headers and real column heights', () {
    final keys = [
      ['a', 'b'],
      ['c'],
    ];
    final aspects = [
      [0.5, 1.0], // section 0 extent 200 (col width 100)
      [1.0],
    ];
    final tops = sectionTops(keys, aspects, 3, 300, 28);
    expect(tops, {'a': 28, 'b': 28, 'c': 28 + 200 + 28});
    expect(sectionOffset(aspects, 0, 3, 300, 28), 0);
    expect(sectionOffset(aspects, 1, 3, 300, 28), 228);
  });

  test('anchoredOffset keeps the top item in place when items above disappear', () {
    final ids = [for (var i = 0; i < 30; i++) 'p$i'];
    final sq = List.filled(30, 1.0);
    final oldTops = sectionTops([ids], [sq], 3, 300, 0);
    // Viewing row 5 (offset 500). Hide two rows above it.
    final kept = ids.where((k) => !{'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}.contains(k)).toList();
    final newTops = sectionTops([kept], [List.filled(kept.length, 1.0)], 3, 300, 0);
    expect(anchoredOffset(500, oldTops, newTops), 300);
    // Hidden items below the view don't move it.
    final kept2 = ids.where((k) => !{'p25', 'p26', 'p27'}.contains(k)).toList();
    final newTops2 = sectionTops([kept2], [List.filled(kept2.length, 1.0)], 3, 300, 0);
    expect(anchoredOffset(500, oldTops, newTops2), 500);
  });

  test('anchoredOffset with mixed heights and nothing left returns sane values', () {
    final oldTops = {'a': 0.0, 'b': 0.0, 'c': 400.0};
    final newTops = {'c': 120.0};
    expect(anchoredOffset(410, oldTops, newTops), 130);
    expect(anchoredOffset(410, oldTops, {}), 410);
    expect(anchoredOffset(10, {'a': 50.0}, {'a': 0.0}), 0);
  });

  testWidgets('masonry sliver reserves each tile size before anything loads', (t) async {
    t.view.physicalSize = const Size(300, 2000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final asp = [0.5, 2.0, 1.0, 1.0, 1.0];
    await t.pumpWidget(MaterialApp(
      home: CustomScrollView(slivers: [
        masonrySliver(asp, 3, (i) => SizedBox.expand(key: ValueKey('t$i'))),
      ]),
    ));
    expect(t.takeException(), isNull);
    Rect r(int i) => t.getRect(find.byKey(ValueKey('t$i')));
    expect(r(0), const Rect.fromLTWH(0, 0, 100, 200));
    expect(r(1), const Rect.fromLTWH(100, 0, 100, 50));
    expect(r(2), const Rect.fromLTWH(200, 0, 100, 100));
    expect(r(3), const Rect.fromLTWH(100, 50, 100, 100));
    expect(r(4), const Rect.fromLTWH(200, 100, 100, 100));
  });
}
