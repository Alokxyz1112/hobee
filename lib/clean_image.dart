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

  @override
  Future<CleanNetworkImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CleanNetworkImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final r = await http.get(Uri.parse(url), headers: headers);
    if (r.statusCode != 200) throw NetworkImageLoadException(statusCode: r.statusCode, uri: Uri.parse(url));
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
