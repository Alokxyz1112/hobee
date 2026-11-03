import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'jpeg_restore.dart';

/// Settings: clean up Reddit's JPEG compression when viewing and saving. ON by default.
final cleanJpegs = ValueNotifier<bool>(true);

/// Settings: what a picture download saves. false = cleaned PNG for JPEGs, true = the original file untouched.
final saveOriginalBytes = ValueNotifier<bool>(false);

/// Background isolate: JPEG bytes -> cleaned RGBA (shrunk to fit [maxPx] wide), or null to use the normal decoder.
(Uint8List, int, int)? cleanRgba((Uint8List, int) a) {
  final r = restoreJpeg(a.$1);
  if (r == null) return null;
  var im = restoredImage(r);
  if (a.$2 > 0 && im.width > a.$2) {
    im = img.copyResize(im, width: a.$2, interpolation: img.Interpolation.average);
  }
  return (Uint8List.fromList(im.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba)), im.width, im.height);
}

/// Background isolate: JPEG bytes -> cleaned PNG at full size, or null when it can't be cleaned (not a JPEG, too big).
Uint8List? cleanPng(Uint8List b) {
  final r = restoreJpeg(b);
  if (r == null) return null;
  return img.encodePng(restoredImage(r), level: 6);
}

bool isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xFF && b[1] == 0xD8;

/// Network image that runs the JPEG cleanup before showing. Anything that isn't a JPEG (or is too big to clean)
/// goes through the normal decoder, capped at [maxPx] wide.
class CleanNetworkImage extends ImageProvider<CleanNetworkImage> {
  final String url;
  final int maxPx;
  final Map<String, String> headers;
  const CleanNetworkImage(this.url, this.maxPx, {this.headers = const {}});

  /// Test seam for the HTTP fetch.
  static Future<http.Response> Function(Uri, {Map<String, String>? headers})? fetcher;

  @override
  Future<CleanNetworkImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CleanNetworkImage key, ImageDecoderCallback decode) {
    final c = SafeImageCompleter();
    c.start(_load(decode, () => c.abandoned));
    return c;
  }

  /// Fetch with a timeout. An expired preview.redd.it link (404/403) is retried once on the i.redd.it original.
  Future<http.Response> _fetch() async {
    Future<http.Response> get(String u) => (fetcher ?? http.get)(Uri.parse(u), headers: headers).timeout(const Duration(seconds: 30));
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      throw NetworkImageLoadException(statusCode: 0, uri: Uri());
    }
    http.Response r;
    try {
      r = await get(url);
    } on TimeoutException {
      throw NetworkImageLoadException(statusCode: 408, uri: uri);
    }
    if (r.statusCode != 200) {
      final alt = redditOriginalOf(url);
      if (alt != null) {
        try {
          final r2 = await get(alt);
          if (r2.statusCode == 200) return r2;
        } catch (_) {}
      }
      // 404/410 = the media was deleted. Expected; the widget shows a quiet 'Removed' state.
      throw NetworkImageLoadException(statusCode: r.statusCode, uri: uri);
    }
    return r;
  }

  Future<ImageInfo> _load(ImageDecoderCallback decode, [bool Function()? abandoned]) async {
    final r = await _fetch();
    if (abandoned?.call() ?? false) throw const ImageAbandoned();
    final b = r.bodyBytes;
    if (isJpeg(b)) {
      final c = await compute(cleanRgba, (b, maxPx));
      if (c != null) {
        final buf = await ui.ImmutableBuffer.fromUint8List(c.$1);
        final desc = ui.ImageDescriptor.raw(buf, width: c.$2, height: c.$3, pixelFormat: ui.PixelFormat.rgba8888);
        final codec = await desc.instantiateCodec();
        return ImageInfo(image: (await codec.getNextFrame()).image);
      }
    }
    final buf = await ui.ImmutableBuffer.fromUint8List(b);
    final codec = await decode(buf, getTargetSize: (w, h) => w > maxPx ? ui.TargetImageSize(width: maxPx) : ui.TargetImageSize(width: w, height: h));
    return ImageInfo(image: (await codec.getNextFrame()).image);
  }

  @override
  bool operator ==(Object other) => other is CleanNetworkImage && other.url == url && other.maxPx == maxPx;
  @override
  int get hashCode => Object.hash(url, maxPx);
}

/// i.redd.it original for a preview.redd.it URL (previews expire, originals often stay).
String? redditOriginalOf(String u) {
  final m = RegExp(r'^https?://preview\.redd\.it/([^?#/]+\.(?:jpe?g|png|gif|webp))', caseSensitive: false).firstMatch(u);
  if (m == null) return null;
  // Newer preview names look like 'some-title-v0-abc123.jpeg'; the original is stored as 'abc123.jpeg'.
  final name = m.group(1)!;
  final v0 = RegExp(r'-v0-([a-z0-9]+\.[a-z]+)$', caseSensitive: false).firstMatch(name);
  return 'https://i.redd.it/${v0?.group(1) ?? name}';
}

/// [urls] plus, right after each expired-prone preview.redd.it link, its i.redd.it original. Order kept, no dupes.
List<String> withRedditOriginals(Iterable<String> urls) {
  final out = <String>{};
  for (final u in urls) {
    if (!u.startsWith('http')) continue;
    out.add(u);
    final o = redditOriginalOf(u);
    if (o != null) out.add(o);
  }
  return out.toList();
}

/// Thrown when nobody is listening any more (tile scrolled away); never shown or logged.
class ImageAbandoned implements Exception {
  const ImageAbandoned();
  @override
  String toString() => 'Image load abandoned';
}

/// True for image errors that are expected in normal use and must never be logged as crashes or close the app.
bool isBenignImageError(Object e) {
  if (e is ImageAbandoned) return true;
  if (e is NetworkImageLoadException) return e.statusCode == 404 || e.statusCode == 410 || e.statusCode == 403;
  final s = '$e';
  return s.contains('Stream has been disposed') || s.contains('HTTP request failed, statusCode: 40');
}

/// One-frame completer that never calls setImage on a disposed stream (the 'Stream has been disposed' crash) and
/// reports expected failures (404, abandoned) silently.
class SafeImageCompleter extends ImageStreamCompleter {
  bool _hadListener = false;

  /// Listeners came and all went (tile scrolled away). The base class disposes the stream at that point.
  bool get abandoned => _hadListener && !hasListeners;

  @override
  void addListener(ImageStreamListener listener) {
    _hadListener = true;
    super.addListener(listener);
  }

  void start(Future<ImageInfo> f) {
    f.then((info) {
      // No early return on 'abandoned': a keepAlive handle (image cache) may still want the frame, and skipping
      // setImage would leave that stream spinning forever. A really disposed stream throws StateError, caught here.
      try {
        setImage(info);
      } catch (_) {
        info.dispose();
      }
    }, onError: (Object e, StackTrace s) {
      if (abandoned || e is ImageAbandoned) return;
      try {
        reportError(context: ErrorDescription('loading a cleaned image'), exception: e, stack: s, silent: isBenignImageError(e));
      } catch (_) {}
    });
  }
}
