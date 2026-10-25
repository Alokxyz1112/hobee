import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hobee/archive.dart';
import 'package:hobee/archive_ui.dart';
import 'package:hobee/models.dart';

Post post(int i) => Post.fromJson({
      'id': 'p$i', 'title': 't', 'subreddit': 's', 'author': 'a', 'permalink': '/p', 'created_utc': 0,
      'url': 'https://i.redd.it/img$i.jpeg', 'post_hint': 'image',
    })!;

void main() {
  final cache = <String, String>{};
  final hits = <String>[];
  var delay = const Duration(milliseconds: 40);
  setUp(() {
    cache.clear();
    hits.clear();
    delay = const Duration(milliseconds: 40);
    MediaCheck.reset();
    MediaCheck.retries = 0;
    MediaCheck.checkTimeout = const Duration(seconds: 25);
    MediaCheck.readCache = (k) async => cache[k];
    MediaCheck.writeCache = (k, v) async => cache[k] = v;
    MediaCheck.wayback = (_) async => null;
    MediaCheck.client = () => MockClient((rq) async {
          hits.add(rq.url.toString());
          await Future.delayed(delay);
          return http.Response('x' * 5000, 200, headers: {'content-type': 'image/jpeg'});
        });
  });

  test('checks for tiles that scrolled away are skipped, visible ones run first', () async {
    final disposed = List.generate(300, (i) => true);
    final skipped = <Future>[];
    for (var i = 0; i < 300; i++) {
      final p = post(i);
      skipped.add(MediaCheck.resolve(p, p.media.first, thumb: true, wanted: () => !disposed[i]));
    }
    final sw = Stopwatch()..start();
    final visible = [for (var i = 300; i < 312; i++) post(i)];
    final res = await Future.wait([for (final p in visible) MediaCheck.resolve(p, p.media.first, thumb: true, wanted: () => true)]);
    sw.stop();
    expect(res.every((u) => u != null), true);
    // Old FIFO queue: 300 checks * 40ms / 6 slots = 2s before the first visible tile even started.
    expect(sw.elapsedMilliseconds, lessThan(800));
    await Future.wait(skipped);
    final probed = hits.map((h) => RegExp(r'img(\d+)').firstMatch(h)?.group(1)).toSet();
    expect(probed.length, lessThan(20), reason: 'only the 6 already running plus the visible ones');
    expect(MediaCheck.activeSlots, 0);
    expect(MediaCheck.queued, 0);
  });

  test('a hung request cannot hold a slot forever, and the timeout is not cached as gone', () async {
    delay = const Duration(hours: 1);
    MediaCheck.checkTimeout = const Duration(milliseconds: 150);
    final ps = [for (var i = 0; i < 20; i++) post(i)];
    final res = await Future.wait([for (final p in ps) MediaCheck.resolve(p, p.media.first, thumb: true)]);
    expect(res.every((u) => u != null), true, reason: 'timeout falls back to the raw url, not gone');
    expect(MediaCheck.gone.value, isEmpty);
    expect(cache.values.where((v) => v.isEmpty), isEmpty);
    expect(MediaCheck.activeSlots, 0);
    // Comes back into view: checks again instead of reusing the stuck future.
    delay = Duration.zero;
    hits.clear();
    await MediaCheck.resolve(ps.first, ps.first.media.first, thumb: true);
    expect(hits, isNotEmpty);
  });

  testWidgets('long scroll over 400 deep tiles: bottom tiles still get checked', (t) async {
    final ps = [for (var i = 0; i < 400; i++) post(i)];
    final ctl = ScrollController();
    await t.pumpWidget(MaterialApp(
      home: GridView.builder(
        controller: ctl,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
        itemCount: ps.length,
        itemBuilder: (_, i) => ArchiveImage(key: ValueKey(i), post: ps[i], item: ps[i].media.first, cacheWidth: 120, deep: true),
      ),
    ));
    await t.runAsync(() async {
      for (var s = 0; s < 60; s++) {
        ctl.jumpTo((ctl.offset + 600).clamp(0, ctl.position.maxScrollExtent));
        await t.pump();
        await Future.delayed(const Duration(milliseconds: 10));
        await t.pump();
      }
      for (var k = 0; k < 40; k++) {
        await Future.delayed(const Duration(milliseconds: 50));
        await t.pump();
      }
    });
    expect(ctl.offset, ctl.position.maxScrollExtent);
    expect(hits.any((h) => h.contains('img399')), true, reason: 'last tile was checked');
    expect(MediaCheck.queued, 0);
    expect(MediaCheck.activeSlots, 0);
    // Only tiles that were on screen when it was their turn got probed, not all 400.
    expect(hits.map((h) => RegExp(r'img(\d+)').firstMatch(h)?.group(1)).toSet().length, lessThan(250));
  });
}
