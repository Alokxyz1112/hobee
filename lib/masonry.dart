import 'dart:math' as math;
import 'package:flutter/widgets.dart';

/// Settings → Grid: true = tiles keep the media's shape (masonry), false = square tiles.
final originalShapeGrid = ValueNotifier<bool>(true);

/// Tile shapes are clamped to this range so one very tall or very wide image can't dominate the grid.
const double minTileAspect = 0.4, maxTileAspect = 2.5;

/// Aspect ratio (width / height) a tile is drawn with. Unknown sizes, and the Square grid setting, give 1.
double tileAspect(double? aspect, {bool square = false}) =>
    square || aspect == null || !aspect.isFinite || aspect <= 0 ? 1.0 : aspect.clamp(minTileAspect, maxTileAspect).toDouble();

/// Shortest-column masonry layout of one section. Ties go to the leftmost column,
/// so equal (square) tiles fill row by row, exactly like a fixed grid.
class Masonry {
  /// Item indices per column, top to bottom.
  final List<List<int>> columns;

  /// Top of each item within the section.
  final List<double> top;

  /// Height of the tallest column.
  final double extent;

  Masonry._(this.columns, this.top, this.extent);

  factory Masonry(List<double> aspects, int cols, double width) {
    final colW = width / cols;
    final heights = List<double>.filled(cols, 0);
    final columns = [for (var c = 0; c < cols; c++) <int>[]];
    final top = List<double>.filled(aspects.length, 0);
    for (var i = 0; i < aspects.length; i++) {
      var c = 0;
      for (var k = 1; k < cols; k++) {
        if (heights[k] < heights[c] - 1e-6) c = k;
      }
      top[i] = heights[c];
      heights[c] += colW / aspects[i];
      columns[c].add(i);
    }
    return Masonry._(columns, top, heights.fold(0.0, math.max));
  }
}

/// Top of every item, measured from the top of the first section, for a list of sections that each
/// start with a header of [headerH]. Keys are taken from [keys] (same shape as [aspects]).
Map<String, double> sectionTops(List<List<String>> keys, List<List<double>> aspects, int cols, double width, double headerH) {
  final out = <String, double>{};
  var y = 0.0;
  for (var s = 0; s < keys.length; s++) {
    final m = Masonry(aspects[s], cols, width);
    y += headerH;
    for (var i = 0; i < keys[s].length; i++) {
      out.putIfAbsent(keys[s][i], () => y + m.top[i]);
    }
    y += m.extent;
  }
  return out;
}

/// Offset of section [s] from the top of the first section.
double sectionOffset(List<List<double>> aspects, int s, int cols, double width, double headerH) {
  var off = 0.0;
  for (var i = 0; i < s && i < aspects.length; i++) {
    off += headerH + Masonry(aspects[i], cols, width).extent;
  }
  return off;
}

/// Keep the view on the same item when items above it disappear or move: take the first item at or below
/// the current offset that is still shown (or the last one above it) and shift by how far it moved.
double anchoredOffset(double offset, Map<String, double> oldTops, Map<String, double> newTops) {
  String? below, above;
  double bestBelow = double.infinity, bestAbove = -double.infinity;
  oldTops.forEach((k, y) {
    if (!newTops.containsKey(k)) return;
    if (y >= offset && y < bestBelow) {
      bestBelow = y;
      below = k;
    } else if (y < offset && y > bestAbove) {
      bestAbove = y;
      above = k;
    }
  });
  final k = below ?? above;
  if (k == null) return offset;
  final o = offset + newTops[k]! - oldTops[k]!;
  return o < 0 ? 0 : o;
}

/// Lazy masonry sliver: [cols] side-by-side lists, each tile sized from its aspect ratio before anything loads.
/// [tile] gets the index into [aspects].
Widget masonrySliver(List<double> aspects, int cols, Widget Function(int index) tile) {
  final m = Masonry(aspects, cols, 1); // column assignment doesn't depend on width
  return SliverCrossAxisGroup(slivers: [
    for (final col in m.columns)
      SliverVariedExtentList(
        itemExtentBuilder: (j, dims) => j < col.length ? dims.crossAxisExtent / aspects[col[j]] : 0.0,
        delegate: SliverChildBuilderDelegate((_, j) => tile(col[j]), childCount: col.length),
      ),
  ]);
}
