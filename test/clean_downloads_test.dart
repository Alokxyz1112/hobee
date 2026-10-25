import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/clean.dart';
import 'package:image/image.dart' as img;

bool has(Uint8List b, String s) {
  final n = latin1.encode(s);
  outer:
  for (var i = 0; i + n.length <= b.length; i++) {
    for (var j = 0; j < n.length; j++) { if (b[i + j] != n[j]) continue outer; }
    return true;
  }
  return false;
}

Uint8List seg(int marker, List<int> payload) =>
    Uint8List.fromList([0xFF, marker, (payload.length + 2) >> 8, (payload.length + 2) & 0xFF, ...payload]);

img.Image pic() => img.Image(width: 8, height: 6)..clear(img.ColorRgb8(200, 30, 30));

const xmp = 'http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta>Hobee reddit.com/r/pics u/author</x:xmpmeta>';

Uint8List dirtyJpeg({int orientation = 1}) {
  final im = pic();
  im.exif.imageIfd['Make'] = 'FakeCam';
  im.exif.imageIfd['Software'] = 'Hobee';
  im.exif.imageIfd.orientation = orientation;
  im.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(12, 1);
  final j = img.encodeJpg(im, quality: 95);
  return Uint8List.fromList([
    ...j.sublist(0, 2),
    ...seg(0xE1, latin1.encode(xmp)),
    ...seg(0xED, latin1.encode('Photoshop 3.0\x008BIM reddit')),
    ...seg(0xFE, latin1.encode('saved from reddit by Hobee')),
    ...j.sublist(2),
  ]);
}

void main() {
  test('JPEG: EXIF, GPS, XMP, IPTC and comments are gone, picture still decodes', () {
    final d = dirtyJpeg();
    expect(has(d, 'Exif'), isTrue);
    final c = stripMetadata(d);
    for (final s in ['Exif', 'FakeCam', 'Hobee', 'reddit', 'xmpmeta', 'ns.adobe.com/xap', '8BIM', 'Photoshop']) {
      expect(has(c, s), isFalse, reason: s);
    }
    final im = img.decodeJpg(c)!;
    expect(im.width, 8);
    expect(im.exif.isEmpty, isTrue);
  });

  test('JPEG with EXIF rotation gets the rotation baked in and still no EXIF', () {
    final c = stripMetadata(dirtyJpeg(orientation: 6));
    expect(has(c, 'Exif'), isFalse);
    final im = img.decodeJpg(c)!;
    expect([im.width, im.height], [6, 8]);
  });

  test('JPEG keeps the ICC profile', () {
    final j = img.encodeJpg(pic());
    final withIcc = Uint8List.fromList([...j.sublist(0, 2), ...seg(0xE2, latin1.encode('ICC_PROFILE\x00\x01\x01abc')), ...j.sublist(2)]);
    expect(has(stripMetadata(withIcc), 'ICC_PROFILE'), isTrue);
  });

  test('PNG: text, iTXt (XMP), eXIf and tIME chunks are removed', () {
    final im = pic()..textData = {'Comment': 'Hobee reddit', 'XML:com.adobe.xmp': '<x:xmpmeta/>'};
    final p = img.encodePng(im);
    expect(has(p, 'Hobee'), isTrue);
    final c = stripMetadata(p);
    for (final s in ['tEXt', 'iTXt', 'zTXt', 'eXIf', 'Hobee', 'xmpmeta']) {
      expect(has(c, s), isFalse, reason: s);
    }
    expect(img.decodePng(c)!.width, 8);
  });

  test('WebP: EXIF and XMP chunks removed and flags cleared', () {
    Uint8List chunk(String t, List<int> d) {
      final h = ByteData(8);
      for (var k = 0; k < 4; k++) { h.setUint8(k, t.codeUnitAt(k)); }
      h.setUint32(4, d.length, Endian.little);
      return Uint8List.fromList([...h.buffer.asUint8List(), ...d, if (d.length.isOdd) 0]);
    }
    final body = [
      ...chunk('VP8X', [0x0C, 0, 0, 0, 7, 0, 0, 5, 0, 0]),
      ...chunk('VP8L', [1, 2, 3, 4]),
      ...chunk('EXIF', latin1.encode('Exif Hobee')),
      ...chunk('XMP ', latin1.encode('<x:xmpmeta>reddit</x:xmpmeta>')),
    ];
    final h = ByteData(12);
    for (var k = 0; k < 4; k++) { h.setUint8(k, 'RIFF'.codeUnitAt(k)); h.setUint8(8 + k, 'WEBP'.codeUnitAt(k)); }
    h.setUint32(4, body.length + 4, Endian.little);
    final c = stripMetadata(Uint8List.fromList([...h.buffer.asUint8List(), ...body]));
    expect(has(c, 'EXIF') || has(c, 'XMP ') || has(c, 'Hobee') || has(c, 'reddit'), isFalse);
    expect(c[20] & 0x0C, 0);
    expect(ByteData.sublistView(c, 4, 8).getUint32(0, Endian.little), c.length - 8);
  });

  test('GIF: comment and XMP extensions removed, still decodes', () {
    final g = img.encodeGif(pic());
    final dirty = Uint8List.fromList([
      ...g.sublist(0, g.length - 1),
      0x21, 0xFE, 11, ...latin1.encode('Hobee reddit'.substring(0, 11)), 0,
      0x21, 0xFF, 11, ...latin1.encode('XMP DataXMP'), 5, ...latin1.encode('<x:x>'), 0,
      0x3B,
    ]);
    final c = stripMetadata(dirty);
    expect(has(c, 'Hobee') || has(c, 'XMP DataXMP'), isFalse);
    expect(img.decodeGif(c)!.width, 8);
  });

  test('Unknown formats (video) are passed through untouched', () {
    final mp4 = Uint8List.fromList([0, 0, 0, 0x18, ...latin1.encode('ftypmp42'), 0, 0, 0, 0]);
    expect(identical(stripMetadata(mp4), mp4), isTrue);
  });

  test('File name is a plain timestamp with no source or camera prefix', () {
    final n = timestampName(DateTime(2026, 10, 25, 23, 39, 0), 'jpg');
    expect(n, '20261025_233900.jpg');
    expect(RegExp(r'^\d{8}_\d{6}\.(jpg|png|gif|webp|mp4)$').hasMatch(timestampName(DateTime.now(), 'png')), isTrue);
    for (final bad in ['hobee', 'reddit', 'IMG_', 'DSC_', 'r_']) {
      expect(n.toLowerCase().contains(bad.toLowerCase()), isFalse);
    }
  });

  test('Clean downloads is on by default', () {
    expect(cleanDownloads.value, isTrue);
  });
}
