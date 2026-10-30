import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/deep_search.dart';
import 'package:hobee/filters.dart' as f;
import 'package:hobee/filters.dart' hide matches;
import 'package:hobee/models.dart';

Post post(int i) => Post.fromJson({
      'id': 'p$i', 'title': i.isEven ? 'cute cat $i' : 'dog $i', 'subreddit': 's', 'author': 'a', 'permalink': '/p', 'created_utc': 1700000000 + i,
      'url': 'https://i.redd.it/img$i.jpeg', 'post_hint': 'image',
    })!;

void main() {
  test('one pass filter matches matches() and publishes counts, fast on 5000 posts', () {
    final all = [for (var i = 0; i < 5000; i++) post(i)];
    searchQuery.value = 'cat';
    final sw = Stopwatch()..start();
    final out = filterAndCount(all);
    sw.stop();
    expect(out.length, all.where(f.matches).length);
    expect(out.length, 2500);
    expect(chipCounts.value[MediaFilter.images], 2500);
    expect(sw.elapsedMilliseconds, lessThan(1500));
    searchQuery.value = '';
  });

  testWidgets('range slider reports only on release', (t) async {
    final ends = <RangeValues>[];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: LiveRange(values: const RangeValues(0, 1), labels: (r) => const RangeLabels('a', 'b'), onEnd: ends.add))));
    final g = await t.startGesture(t.getTopLeft(find.byType(RangeSlider)) + const Offset(30, 24));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(10, 0));
      await t.pump();
    }
    expect(ends, isEmpty);
    await g.up();
    await t.pump();
    expect(ends.length, 1);
  });
}
