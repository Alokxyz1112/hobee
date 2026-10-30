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

  Future<ImageInfo> _load(ImageDecoderCallback decode, [bool Function()? abandoned]) async {
    final r = await (fetcher ?? http.get)(Uri.parse(url), headers: headers);
    // 404/410 = the media was deleted. Expected; the widget shows a quiet 'Removed' state.
    if (r.statusCode != 200) throw NetworkImageLoadException(statusCode: r.statusCode, uri: Uri.parse(url));
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
      if (abandoned) {
        info.dispose();
        return;
      }
      try {
        setImage(info);
      } on StateError {
        info.dispose(); // disposed between the check and the call
      }
    }, onError: (Object e, StackTrace s) {
      if (abandoned || e is ImageAbandoned) return;
      try {
        reportError(context: ErrorDescription('loading a cleaned image'), exception: e, stack: s, silent: isBenignImageError(e));
      } catch (_) {}
    });
  }
}
