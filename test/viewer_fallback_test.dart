import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));

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
