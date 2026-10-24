import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'models.dart';

const _ch = MethodChannel('hobee/media');

class Downloader {
  static Future<File> _fetch(String url, String name) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$name');
    final r = await http.get(Uri.parse(url), headers: {'User-Agent': 'android:com.alok.hobee:v1.0'});
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    await f.writeAsBytes(r.bodyBytes);
    return f;
  }

  static Future<void> _perm() async {
    if (Platform.isAndroid) {
      final info = await _ch.invokeMethod<int>('sdk').catchError((_) => 99);
      if ((info ?? 99) <= 28) await Permission.storage.request();
    }
  }

  static String _ext(String url, String def) {
    final m = RegExp(r'\.(jpe?g|png|gif|webp|mp4)(\?|$)', caseSensitive: false).firstMatch(url);
    return m != null ? m.group(1)!.toLowerCase() : def;
  }

  static String _mime(String ext) => switch (ext) {
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'mp4' => 'video/mp4',
        _ => 'image/jpeg',
      };

  /// Downloads one media item and saves it to Pictures/Hobee or Movies/Hobee.
  static Future<String> save(MediaItem m, String baseName) async {
    await _perm();
    final ts = DateTime.now().millisecondsSinceEpoch;
    if (m.type == MediaType.video) {
      final best = m.redditVideo ? await _bestDash(m.url) : null;
      File video;
      try {
        video = await _fetch(best ?? m.url, 'v_$ts.mp4');
      } catch (_) {
        if (best == null) rethrow;
        video = await _fetch(m.url, 'v_$ts.mp4');
      }
      File out = video;
      if (m.redditVideo) {
        final audio = await _redditAudio(m.url, ts);
        if (audio != null) {
          final merged = File('${video.parent.path}/m_$ts.mp4');
          try {
            await _ch.invokeMethod('mux', {'video': video.path, 'audio': audio.path, 'out': merged.path});
            out = merged;
          } catch (_) {
            out = video; // fallback: video without audio
          }
        }
      }
      final name = '${baseName}_$ts.mp4';
      final r = await _ch.invokeMethod<String>('save', {'path': out.path, 'name': name, 'mime': 'video/mp4', 'video': true});
      return r ?? name;
    } else {
      // Original upload first (Settings → Original quality), then the preview copy if the original fails.
      var src = m.full;
      File f;
      try {
        f = await _fetch(src, 'i_$ts.${_ext(src, 'jpg')}');
      } catch (_) {
        final alt = m.preview != null && m.preview != src ? m.preview! : (m.url != src ? m.url : null);
        if (alt == null) rethrow;
        src = alt;
        f = await _fetch(src, 'i_$ts.${_ext(src, 'jpg')}');
      }
      final ext = _ext(src, 'jpg');
      final name = '${baseName}_$ts.$ext';
      final r = await _ch.invokeMethod<String>('save', {'path': f.path, 'name': name, 'mime': _mime(ext), 'video': false});
      return r ?? name;
    }
  }

  /// Highest-bandwidth video representation from v.redd.it's DASHPlaylist.mpd (fallback_url is not always the top one).
  static Future<String?> _bestDash(String fallbackUrl) async {
    final base = fallbackUrl.split('?').first.replaceAll(RegExp(r'/[^/]*$'), '');
    try {
      final r = await http.get(Uri.parse('$base/DASHPlaylist.mpd')).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      return bestDashVideo(r.body, base);
    } catch (_) {
      return null;
    }
  }

  /// Reddit serves audio separately. Try DASHPlaylist.mpd first, then known file names.
  static Future<File?> _redditAudio(String fallbackUrl, int ts) async {
    final base = fallbackUrl.split('?').first.replaceAll(RegExp(r'/[^/]*$'), '');
    final cands = <String>[];
    try {
      final r = await http.get(Uri.parse('$base/DASHPlaylist.mpd'));
      if (r.statusCode == 200) {
        final adapt = RegExp(r'<AdaptationSet[^>]*contentType="audio"[\s\S]*?</AdaptationSet>').firstMatch(r.body)?.group(0) ??
            RegExp(r'<AdaptationSet[^>]*mimeType="audio[\s\S]*?</AdaptationSet>').firstMatch(r.body)?.group(0);
        if (adapt != null) {
          final urls = RegExp(r'<BaseURL>([^<]+)</BaseURL>').allMatches(adapt).map((e) => e.group(1)!).toList();
          cands.addAll(urls.reversed.map((u) => u.startsWith('http') ? u : '$base/$u'));
        }
      }
    } catch (_) {}
    cands.addAll(['$base/DASH_AUDIO_128.mp4', '$base/DASH_AUDIO_64.mp4', '$base/DASH_audio.mp4', '$base/audio']);
    for (final c in cands) {
      try {
        return await _fetch(c, 'a_$ts.mp4');
      } catch (_) {}
    }
    return null;
  }
}

/// Picks the highest-bandwidth video BaseURL from a DASH manifest.
String? bestDashVideo(String mpd, String base) {
  String? best;
  var bw = -1;
  for (final set in RegExp(r'<AdaptationSet[\s\S]*?</AdaptationSet>').allMatches(mpd)) {
    final a = set.group(0)!;
    if (a.contains('audio')) continue;
    for (final rep in RegExp(r'<Representation[^>]*bandwidth="(\d+)"[\s\S]*?<BaseURL>([^<]+)</BaseURL>').allMatches(a)) {
      final b = int.parse(rep.group(1)!);
      if (b > bw) { bw = b; final u = rep.group(2)!; best = u.startsWith('http') ? u : '$base/$u'; }
    }
  }
  return best;
}
