import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/models.dart';
import 'package:hobee/viewer.dart';
import 'package:image/image.dart' as img;

class _Fail extends ImageProvider<_Fail> {
  final String url;
  _Fail(this.url);
  @override
  Future<_Fail> obtainKey(ImageConfiguration c) => SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(_Fail key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Future.error(Exception('HTTP request failed, statusCode: 403, $url')));
  @override
  bool operator ==(Object o) => o is _Fail && o.url == url;
  @override
  int get hashCode => url.hashCode;
}

/// Never finishes loading (a slow original).
class _Pending extends ImageProvider<_Pending> {
  final String url;
  final Completer<ImageInfo> done = Completer();
  _Pending(this.url);
  @override
  Future<_Pending> obtainKey(ImageConfiguration c) => SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(_Pending key, ImageDecoderCallback decode) => OneFrameImageStreamCompleter(done.future);
}

Entry _entry(String id, MediaType type) {
  final m = MediaItem(type, 'https://i.redd.it/$id.jpg', 'https://t/$id.jpg');
  return Entry(Post(id, 't', 's', 'a', '/p', 0, [m], const {}), m, 0);
}

void main() {
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));

  testWidgets('shows the thumbnail at once while the original loads, then fades the original in', (t) async {
    final k = GlobalKey<PhotoFallbackState>();
    final thumb = MemoryImage(png);
    final slow = _Pending('https://a/orig.jpg');
    await t.pumpWidget(MaterialApp(home: PhotoFallback(key: k, urls: const ['https://a/orig.jpg'], placeholder: thumb, providerFor: (_, _) => slow)));
    await t.pump(const Duration(milliseconds: 50));
    expect(find.byWidgetPredicate((w) => w is Image && w.image == thumb), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'only the small corner spinner');
    expect(find.byKey(const Key('full-loading')), findsOneWidget);
    final box = t.getRect(find.byKey(const Key('full-loading')));
    final screen = t.getRect(find.byType(PhotoFallback));
    expect(box.right, greaterThan(screen.width - 60), reason: 'right edge');
    expect(box.top, lessThan(screen.height / 4), reason: 'top, under the title bar');
    expect(k.currentState!.loaded, isFalse);
    expect(t.widget<AnimatedOpacity>(find.byKey(const Key('full-fade'))).opacity, 0);

    final decoded = await t.runAsync(() => decodeImageFromList(png));
    slow.done.complete(ImageInfo(image: decoded!));
    await t.pump();
    await t.pump(const Duration(milliseconds: 250));
    expect(k.currentState!.loaded, isTrue);
    expect(t.widget<AnimatedOpacity>(find.byKey(const Key('full-fade'))).opacity, 1);
    expect(find.byKey(const Key('full-loading')), findsNothing);
  });

  testWidgets('original fails -> stays on the thumbnail quietly, no error screen', (t) async {
    final k = GlobalKey<PhotoFallbackState>();
    final thumb = MemoryImage(png);
    await t.pumpWidget(MaterialApp(home: PhotoFallback(key: k, urls: const ['https://a/1.jpg', 'https://a/2.jpg'], placeholder: thumb, providerFor: (u, _) => _Fail(u))));
    for (var n = 0; n < 8; n++) { await t.pump(const Duration(milliseconds: 50)); }
    expect(k.currentState!.failures.length, 2);
    expect(find.byWidgetPredicate((w) => w is Image && w.image == thumb), findsOneWidget);
    expect(find.textContaining("Couldn't load image"), findsNothing);
    expect(find.byKey(const Key('quiet-retry')), findsOneWidget);
  });

  test('prefetchTargets: next two positions, images only', () {
    final es = [
      _entry('a', MediaType.image),
      _entry('b', MediaType.video),
      _entry('c', MediaType.image),
      _entry('d', MediaType.image),
    ];
    expect(prefetchTargets(es, 0), [2]); // b is a video
    expect(prefetchTargets(es, 1), [2, 3]);
    expect(prefetchTargets(es, 3), isEmpty);
    expect(prefetchTargets(es, 0, ahead: 3), [2, 3]);
  });

  testWidgets('falls through failing URLs to the first one that loads, even with rebuilds', (t) async {
    final requested = <String>[];
    final k = GlobalKey<PhotoFallbackState>();
    late StateSetter rebuild;
    await t.pumpWidget(MaterialApp(home: StatefulBuilder(builder: (c, ss) {
      rebuild = ss;
      return PhotoFallback(key: k, urls: const ['https://a/orig.jpg', 'https://a/preview.jpg', 'https://a/thumb.jpg'], providerFor: (u, _) {
        requested.add(u);
        return u.contains('thumb') ? MemoryImage(png) : _Fail(u);
      });
    })));
    for (var n = 0; n < 12; n++) {
      rebuild(() {}); // page changes / chrome toggles rebuild the viewer
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(k.currentState!.i, 2, reason: 'should stop on the thumbnail, not skip past it');
    expect(k.currentState!.failures.length, 2);
    expect(k.currentState!.failures.first, contains('HTTP 403'));
    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets('all fail -> retry restarts from the first URL', (t) async {
    final k = GlobalKey<PhotoFallbackState>();
    var calls = 0;
    await t.pumpWidget(MaterialApp(home: PhotoFallback(key: k, urls: const ['https://a/1.jpg', 'https://a/2.jpg'], providerFor: (u, _) { calls++; return _Fail(u); })));
    for (var n = 0; n < 8; n++) { await t.pump(const Duration(milliseconds: 50)); }
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    final before = calls;
    await t.tap(find.byIcon(Icons.refresh));
    await t.pump();
    expect(k.currentState!.failures.length, lessThanOrEqualTo(1)); // chain restarted
    expect(calls, greaterThan(before));
  });
}
