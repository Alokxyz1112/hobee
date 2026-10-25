import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/upscale.dart';

/// Fake 4x "model": 3x3 box blur (edge pixels repeat) then nearest-neighbour 4x. It needs neighbours, so any seam
/// or off-by-one in tiling shows up as a mismatch against running it on the whole image.
List<double> fakeModel(Float32List x, int w, int h) {
  final plane = w * h, out = List<double>.filled(3 * plane * 16, 0);
  for (var c = 0; c < 3; c++) {
    for (var y = 0; y < h; y++) {
      for (var xx = 0; xx < w; xx++) {
        var s = 0.0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            s += x[c * plane + (y + dy).clamp(0, h - 1) * w + (xx + dx).clamp(0, w - 1)];
          }
        }
        for (var a = 0; a < 4; a++) {
          for (var b = 0; b < 4; b++) {
            out[c * plane * 16 + (y * 4 + a) * w * 4 + xx * 4 + b] = s / 9;
          }
        }
      }
    }
  }
  return out;
}

void main() {
  test('planTiles covers every pixel exactly once', () {
    for (final (w, h, s) in [(1, 1, 128), (128, 128, 128), (129, 50, 128), (300, 257, 96), (37, 23, 8)]) {
      final hit = List.filled(w * h, 0);
      for (final t in planTiles(w, h, s)) {
        expect(t.w <= s && t.h <= s && t.w > 0 && t.h > 0, true);
        for (var y = t.y; y < t.y + t.h; y++) {
          for (var x = t.x; x < t.x + t.w; x++) {
            hit[y * w + x]++;
          }
        }
      }
      expect(hit.every((v) => v == 1), true, reason: '$w x $h tile $s');
    }
  });

  test('tiled upscale is seamless and equals running on the whole image', () async {
    final r = Random(1);
    for (final (w, h) in [(37, 23), (8, 8), (5, 17)]) {
      final rgb = Uint8List.fromList(List.generate(w * h * 3, (_) => r.nextInt(256)));
      final whole = await upscaleRgb(rgb, w, h, (x, s) async => fakeModel(x, s, s), size: max(w, h), pad: 0);
      // Whole-image reference with the real image shape (no padding to a square): build it directly.
      final full = Float32List(3 * w * h);
      for (var i = 0; i < w * h; i++) {
        for (var c = 0; c < 3; c++) {
          full[c * w * h + i] = rgb[i * 3 + c] / 255;
        }
      }
      final ref = fakeModel(full, w, h);
      final refRgb = Uint8List(w * h * 48);
      for (var i = 0; i < w * h * 16; i++) {
        for (var c = 0; c < 3; c++) {
          refRgb[i * 3 + c] = (ref[c * w * h * 16 + i] * 255 + .5).clamp(0, 255).toInt();
        }
      }
      expect(whole, refRgb, reason: 'single tile $w x $h');
      final tiled = await upscaleRgb(rgb, w, h, (x, s) async => fakeModel(x, s, s), size: 8, pad: 2);
      expect(tiled, refRgb, reason: 'tiled $w x $h');
    }
  });

  test('cancel stops between tiles and progress reports every tile', () async {
    final rgb = Uint8List(40 * 40 * 3);
    final seen = <int>[];
    var n = 0;
    await expectLater(
        upscaleRgb(rgb, 40, 40, (x, s) async => fakeModel(x, s, s), size: 8, pad: 1,
            progress: (d, t) => seen.add(d), cancelled: () => ++n > 3),
        throwsA(isA<UpscaleCancelled>()));
    expect(seen, [1, 2, 3]);
    final all = <int>[];
    await upscaleRgb(rgb, 20, 12, (x, s) async => fakeModel(x, s, s), size: 8, pad: 1, progress: (d, t) { all.add(d); expect(t, 6); });
    expect(all, [1, 2, 3, 4, 5, 6]);
  });
}
