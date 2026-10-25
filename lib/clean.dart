import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Settings toggle: strip metadata from saved files. ON by default.
final cleanDownloads = ValueNotifier<bool>(true);

String _two(int n) => n.toString().padLeft(2, '0');

/// Plain timestamp file name, for example 20261025_233900.jpg.
/// Collisions get a suffix (_1, _2, ...) on the device side.
String timestampName(DateTime t, String ext) =>
    '${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}.$ext';

/// Removes EXIF, XMP, IPTC, comments and text chunks. Keeps only what is needed to
/// show the picture correctly (ICC profile, JFIF/Adobe color markers). Adds nothing.
/// Returns the input unchanged for formats it does not know (videos).
Uint8List stripMetadata(Uint8List b) {
  if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8) return _jpeg(b);
  if (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return _png(b);
  if (b.length > 12 && _ascii(b, 0, 4) == 'RIFF' && _ascii(b, 8, 4) == 'WEBP') return _webp(b);
  if (b.length > 6 && _ascii(b, 0, 3) == 'GIF') return _gif(b);
  return b;
}

String _ascii(Uint8List b, int o, int n) => o + n > b.length ? '' : String.fromCharCodes(b.sublist(o, o + n));

/// EXIF orientation (1 if none), so dropping EXIF does not rotate the picture.
int _orientation(Uint8List seg) {
  try {
    final d = img.ExifData.fromInputBuffer(img.InputBuffer(seg.sublist(6)));
    return d.imageIfd.orientation ?? 1;
  } catch (_) {
    return 1;
  }
}

Uint8List _jpeg(Uint8List b) {
  final out = BytesBuilder(copy: false)..add([0xFF, 0xD8]);
  var i = 2;
  var orient = 1;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return b; // not a clean marker stream, leave it alone
    final m = b[i + 1];
    if (m == 0xFF) { i++; continue; }
    if (m == 0xDA) { out.add(b.sublist(i)); break; } // start of scan: rest is image data
    if (m == 0xD9) { out.add(b.sublist(i)); break; }
    final len = (b[i + 2] << 8) | b[i + 3];
    final end = i + 2 + len;
    if (end > b.length) return b;
    final seg = b.sublist(i + 4, end);
    var keep = true;
    if (m == 0xFE) {
      keep = false; // comment
    } else if (m >= 0xE0 && m <= 0xEF) {
      final id = _ascii(seg, 0, seg.length < 12 ? seg.length : 12);
      if (m == 0xE1 && id.startsWith('Exif')) orient = _orientation(seg);
      keep = (m == 0xE0 && id.startsWith('JFIF')) || (m == 0xE2 && id.startsWith('ICC_PROFILE')) || (m == 0xEE && id.startsWith('Adobe'));
    }
    if (keep) out.add(b.sublist(i, end));
    i = end;
  }
  final clean = out.toBytes();
  if (orient == 1) return clean;
  // The picture relied on EXIF rotation: bake it into the pixels and re-encode at q95.
  final im = img.decodeJpg(b);
  if (im == null) return clean;
  final baked = img.bakeOrientation(im)..exif = img.ExifData();
  return stripMetadata(img.encodeJpg(baked, quality: 95));
}

const _pngDrop = {'tEXt', 'zTXt', 'iTXt', 'eXIf', 'tIME'};

Uint8List _png(Uint8List b) {
  final out = BytesBuilder(copy: false)..add(b.sublist(0, 8));
  var i = 8;
  while (i + 12 <= b.length) {
    final len = ByteData.sublistView(b, i, i + 4).getUint32(0);
    final type = _ascii(b, i + 4, 4);
    final end = i + 12 + len;
    if (end > b.length) return b;
    if (!_pngDrop.contains(type)) out.add(b.sublist(i, end));
    i = end;
    if (type == 'IEND') break;
  }
  return out.toBytes();
}

Uint8List _webp(Uint8List b) {
  final body = BytesBuilder(copy: false);
  var i = 12;
  while (i + 8 <= b.length) {
    final type = _ascii(b, i, 4);
    final len = ByteData.sublistView(b, i + 4, i + 8).getUint32(0, Endian.little);
    var end = i + 8 + len + (len & 1);
    if (end > b.length) end = b.length;
    if (type == 'VP8X') {
      final c = Uint8List.fromList(b.sublist(i, end));
      c[8] &= ~0x0C; // clear EXIF (0x08) and XMP (0x04) flags
      body.add(c);
    } else if (type != 'EXIF' && type != 'XMP ') {
      body.add(b.sublist(i, end));
    }
    i = end;
  }
  final data = body.toBytes();
  final hdr = ByteData(12);
  for (var k = 0; k < 4; k++) { hdr.setUint8(k, 'RIFF'.codeUnitAt(k)); hdr.setUint8(8 + k, 'WEBP'.codeUnitAt(k)); }
  hdr.setUint32(4, data.length + 4, Endian.little);
  return (BytesBuilder(copy: false)..add(hdr.buffer.asUint8List())..add(data)).toBytes();
}

/// GIF: drops comment extensions and application extensions other than the
/// looping ones (NETSCAPE2.0 / ANIMEXTS1.0), which is where XMP lives.
Uint8List _gif(Uint8List b) {
  try {
    final out = BytesBuilder(copy: false);
    var i = 13;
    final flags = b[10];
    if (flags & 0x80 != 0) i += 3 * (1 << ((flags & 7) + 1));
    out.add(b.sublist(0, i));
    int skipSub(int p) {
      while (b[p] != 0) { p += b[p] + 1; }
      return p + 1;
    }
    while (i < b.length) {
      final c = b[i];
      if (c == 0x3B) { out.addByte(0x3B); break; }
      if (c == 0x21) {
        final label = b[i + 1];
        final end = skipSub(i + 2);
        var keep = label != 0xFE;
        if (label == 0xFF) {
          final id = _ascii(b, i + 3, 11);
          keep = id == 'NETSCAPE2.0' || id == 'ANIMEXTS1.0';
        }
        if (keep) out.add(b.sublist(i, end));
        i = end;
      } else if (c == 0x2C) {
        var p = i + 10;
        final f = b[i + 9];
        if (f & 0x80 != 0) p += 3 * (1 << ((f & 7) + 1));
        p = skipSub(p + 1); // LZW min code size, then data
        out.add(b.sublist(i, p));
        i = p;
      } else {
        return b;
      }
    }
    return out.toBytes();
  } catch (_) {
    return b;
  }
}
