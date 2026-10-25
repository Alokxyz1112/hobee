import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Image upscaling (super resolution) with Real-ESRGAN models, fully on the phone.
///
/// Every model here is a native 4x model. 2x and 3x are made by running the 4x model and then shrinking the
/// result with a high quality filter. That still looks better than a plain resize, but it's not a separate 2x net.
///
/// Real-ESRGAN by Xintao Wang et al., BSD-3-Clause, https://github.com/xinntao/Real-ESRGAN
/// The ONNX files are straight conversions of the official .pth weights (same numbers, see README).
enum UpModel {
  fast('Fast', 'realesr-general-x4v3', 'Small and quick. Good on photos and screenshots.', null, 0, ''),
  ultra('Ultra', 'RealESRGAN_x4plus', 'Best detail on photos. Big download, slow.', 'RealESRGAN_x4plus.onnx', 67051616,
      'aeda30ebfe7519d087071902b8198bbdfc08a5ba8457969fc8c453c3010bc57c'),
  art('Art', 'RealESRGAN_x4plus_anime_6B', 'Drawings, anime and memes. Clean lines.', 'RealESRGAN_x4plus_anime_6B.onnx',
      17939941, 'd0c0ba25911cdc60151a1bdb33b4cc3d7beb86317b6d1540a290d78e0a0d8255');

  final String label, name, hint;
  final String? file; // null = bundled in the APK
  final int approxBytes;
  final String sha;
  const UpModel(this.label, this.name, this.hint, this.file, this.approxBytes, this.sha);
  bool get bundled => file == null;
}

const modelBase = 'https://github.com/Alokxyz1112/hobee/releases/download/models-v1/';

/// Core rectangle of the input that one tile is responsible for.
class Tile {
  final int x, y, w, h;
  const Tile(this.x, this.y, this.w, this.h);
  @override
  String toString() => 'Tile($x,$y,$w,$h)';
}

/// Splits a w*h image into tiles of at most [size] px so a big image never has to fit through the model at once.
List<Tile> planTiles(int w, int h, int size) => [
      for (var y = 0; y < h; y += size)
        for (var x = 0; x < w; x += size) Tile(x, y, math.min(size, w - x), math.min(size, h - y))
    ];

/// Cuts tile [t] plus [pad] px of context on every side out of an RGB buffer as a 1x3xSxS float tensor
/// (S = size + 2*pad, always the same so the model sees one fixed shape). Pixels outside the image repeat the edge.
Float32List extractTile(Uint8List rgb, int w, int h, Tile t, int size, int pad) {
  final s = size + 2 * pad, plane = s * s;
  final out = Float32List(3 * plane);
  for (var yy = 0; yy < s; yy++) {
    final sy = (t.y - pad + yy).clamp(0, h - 1);
    for (var xx = 0; xx < s; xx++) {
      final sx = (t.x - pad + xx).clamp(0, w - 1);
      final i = (sy * w + sx) * 3, o = yy * s + xx;
      out[o] = rgb[i] / 255;
      out[plane + o] = rgb[i + 1] / 255;
      out[2 * plane + o] = rgb[i + 2] / 255;
    }
  }
  return out;
}

/// Copies the model output for tile [t] (a 1x3x(S*scale)x(S*scale) tensor) into the big RGB output, dropping the
/// padded context so neighbouring tiles meet without seams.
void pasteTile(Uint8List out, int outW, List<num> y, Tile t, int size, int pad, int scale) {
  final s = (size + 2 * pad) * scale, plane = s * s;
  final px = pad * scale;
  for (var yy = 0; yy < t.h * scale; yy++) {
    final row = ((t.y * scale + yy) * outW + t.x * scale) * 3;
    final src = (yy + px) * s + px;
    for (var xx = 0; xx < t.w * scale; xx++) {
      final o = row + xx * 3, i = src + xx;
      out[o] = (y[i] * 255 + .5).clamp(0, 255).toInt();
      out[o + 1] = (y[plane + i] * 255 + .5).clamp(0, 255).toInt();
      out[o + 2] = (y[2 * plane + i] * 255 + .5).clamp(0, 255).toInt();
    }
  }
}

/// Runs [model] (any function from a 1x3xSxS tensor to a 1x3x(4S)x(4S) tensor) over the whole image tile by tile.
Future<Uint8List> upscaleRgb(Uint8List rgb, int w, int h, Future<List<num>> Function(Float32List, int s) model,
    {int size = 128, int pad = 10, int scale = 4, void Function(int done, int total)? progress, bool Function()? cancelled}) async {
  final out = Uint8List(w * scale * h * scale * 3);
  final tiles = planTiles(w, h, size);
  for (var i = 0; i < tiles.length; i++) {
    if (cancelled?.call() ?? false) throw const UpscaleCancelled();
    final t = tiles[i];
    final y = await model(extractTile(rgb, w, h, t, size, pad), size + 2 * pad);
    pasteTile(out, w * scale, y, t, size, pad, scale);
    progress?.call(i + 1, tiles.length);
  }
  return out;
}

class UpscaleCancelled implements Exception {
  const UpscaleCancelled();
  @override
  String toString() => 'Cancelled';
}

class UpscaleResult {
  final Uint8List png;
  final int w, h, srcW, srcH;
  final bool shrunk; // input had to be made smaller first to keep memory sane
  UpscaleResult(this.png, this.w, this.h, this.srcW, this.srcH, this.shrunk);
}

/// Largest output we build, in pixels (about 64 MB of RGB while working).
const maxOutPixels = 20000000;

class _Decoded {
  final Uint8List rgb;
  final int w, h, ow, oh;
  _Decoded(this.rgb, this.w, this.h, this.ow, this.oh);
}

_Decoded _decode((Uint8List, int) a) {
  var im = img.decodeImage(a.$1);
  if (im == null) throw Exception('Could not read this image');
  final ow = im.width, oh = im.height;
  // The 4x intermediate (16x the pixels) has to stay under maxOutPixels.
  final maxIn = maxOutPixels / 16;
  if (ow * oh > maxIn) {
    final f = math.sqrt(maxIn / (ow * oh));
    im = img.copyResize(im, width: (ow * f).floor(), height: (oh * f).floor(), interpolation: img.Interpolation.average);
  }
  im = im.convert(numChannels: 3, format: img.Format.uint8);
  return _Decoded(Uint8List.fromList(im.getBytes(order: img.ChannelOrder.rgb)), im.width, im.height, ow, oh);
}

Uint8List _finish((Uint8List, int, int, int, int) a) {
  var im = img.Image.fromBytes(width: a.$2, height: a.$3, bytes: a.$1.buffer, numChannels: 3, order: img.ChannelOrder.rgb);
  if (im.width != a.$4) im = img.copyResize(im, width: a.$4, height: a.$5, interpolation: img.Interpolation.cubic);
  return img.encodePng(im, level: 6);
}

class Upscaler {
  static final _ort = OnnxRuntime();
  static final Map<UpModel, OrtSession> _sessions = {};

  static Future<File> _file(UpModel m) async => File('${(await getApplicationSupportDirectory()).path}/models/${m.file}');

  static Future<bool> ready(UpModel m) async => m.bundled || await (await _file(m)).exists();

  /// Downloads an optional model from this app's own GitHub release (converted from the official weights).
  static Future<void> download(UpModel m, {void Function(double)? progress, bool Function()? cancelled}) async {
    final f = await _file(m);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.part');
    final c = http.Client();
    try {
      final r = await c.send(http.Request('GET', Uri.parse('$modelBase${m.file}')));
      if (r.statusCode != 200) throw Exception('Download failed (HTTP ${r.statusCode})');
      final total = r.contentLength ?? m.approxBytes;
      final sink = tmp.openWrite();
      var got = 0;
      try {
        await for (final chunk in r.stream) {
          if (cancelled?.call() ?? false) throw const UpscaleCancelled();
          sink.add(chunk);
          got += chunk.length;
          progress?.call(got / total);
        }
      } finally {
        await sink.close();
      }
      if (m.sha.isNotEmpty && sha256.convert(await tmp.readAsBytes()).toString() != m.sha) {
        throw Exception('Downloaded model looks broken, try again');
      }
      await tmp.rename(f.path);
    } catch (_) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    } finally {
      c.close();
    }
  }

  static Future<OrtSession> _session(UpModel m) async {
    final s = _sessions[m];
    if (s != null) return s;
    // XNNPACK is the fast ARM CPU path; plain CPU is the fallback. NNAPI is skipped on purpose: these nets use ops it
    // handles badly and it was slower than XNNPACK in ONNX Runtime's own numbers for conv heavy models.
    final opts = OrtSessionOptions(providers: [OrtProvider.XNNPACK, OrtProvider.CPU], intraOpNumThreads: 4);
    OrtSession ses;
    try {
      ses = m.bundled
          ? await _ort.createSessionFromAsset('assets/models/${m.name}.onnx', options: opts)
          : await _ort.createSession((await _file(m)).path, options: opts);
    } catch (_) {
      final cpu = OrtSessionOptions(providers: [OrtProvider.CPU], intraOpNumThreads: 4);
      ses = m.bundled
          ? await _ort.createSessionFromAsset('assets/models/${m.name}.onnx', options: cpu)
          : await _ort.createSession((await _file(m)).path, options: cpu);
    }
    return _sessions[m] = ses;
  }

  /// Upscales encoded image bytes by [scale] (2, 3 or 4) and returns a PNG.
  static Future<UpscaleResult> run(Uint8List bytes, int scale, UpModel m,
      {void Function(double)? progress, bool Function()? cancelled}) async {
    assert(scale >= 2 && scale <= 4);
    final d = await Isolate.run(() => _decode((bytes, scale)));
    final ses = await _session(m);
    final tile = m == UpModel.ultra ? 96 : 128; // smaller tiles for the big net so phones with little RAM survive
    final rgb4 = await upscaleRgb(d.rgb, d.w, d.h, (x, s) async {
      final input = await OrtValue.fromList(x, [1, 3, s, s]);
      try {
        final out = await ses.run({'input': input});
        final v = out['output']!;
        final list = (await v.asFlattenedList()).cast<num>();
        await v.dispose();
        return list;
      } finally {
        await input.dispose();
      }
    }, size: tile, pad: 16, progress: (a, b) => progress?.call(a / b), cancelled: cancelled);
    final tw = d.w * scale, th = d.h * scale;
    final png = await Isolate.run(() => _finish((rgb4, d.w * 4, d.h * 4, tw, th)));
    if (kDebugMode) debugPrint('upscale ${d.w}x${d.h} -> ${tw}x$th with ${m.name}');
    return UpscaleResult(png, tw, th, d.ow, d.oh, d.w != d.ow);
  }
}
