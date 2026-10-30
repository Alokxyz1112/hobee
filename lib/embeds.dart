import 'dart:convert';
import 'package:http/http.dart' as http;

/// Turns RedGIFs / Streamable / v.redd.it links into something the player can stream.
class Embeds {
  static const ua = 'Mozilla/5.0 (Linux; Android 14) Hobee';
  static String? _token;
  static DateTime _tokenUntil = DateTime(2000);
  static final _cache = <String, String>{};
  static http.Client client = http.Client();

  /// RedGIFs id (lowercase) from watch/ifr pages, i./v3./media. hosts. Null if not RedGIFs.
  static String? redgifsId(String url) {
    final u = url.trim();
    if (!RegExp(r'^https?://([a-z0-9]+\.)?redgifs\.com/', caseSensitive: false).hasMatch(u)) return null;
    final m = RegExp(r'redgifs\.com/(?:watch|ifr|i)/([A-Za-z]+)', caseSensitive: false).firstMatch(u) ??
        RegExp(r'redgifs\.com/([A-Za-z]+)(?:-[a-z]+)?(?:\.(?:mp4|jpg|webm|gif))?(?:[?#].*)?$', caseSensitive: false).firstMatch(u);
    final id = m?.group(1)?.toLowerCase();
    if (id == null || const {'watch', 'ifr', 'i', 'users', 'gifs', 'browse'}.contains(id)) return null;
    return id;
  }

  static String? streamableId(String url) =>
      RegExp(r'^https?://(?:www\.)?streamable\.com/(?:[eo]/)?([A-Za-z0-9]+)', caseSensitive: false).firstMatch(url.trim())?.group(1);

  /// v.redd.it base like https://v.redd.it/abc123 from any DASH / fallback / hls url.
  static String? vreddit(String url) {
    final m = RegExp(r'^https?://v\.redd\.it/([A-Za-z0-9]+)').firstMatch(url);
    return m == null ? null : 'https://v.redd.it/${m.group(1)}';
  }

  /// HLS playlist for a v.redd.it video (has the audio track, fallback mp4 doesn't).
  static String? redditHls(String url) {
    final b = vreddit(url);
    return b == null ? null : '$b/HLSPlaylist.m3u8';
  }

  static bool needsResolve(String url) => redgifsId(url) != null && !url.contains('.mp4') || streamableId(url) != null;

  static Future<String> _redgifsToken({bool fresh = false}) async {
    if (!fresh && _token != null && DateTime.now().isBefore(_tokenUntil)) return _token!;
    final r = await client.get(Uri.parse('https://api.redgifs.com/v2/auth/temporary'), headers: {'User-Agent': ua});
    if (r.statusCode != 200) throw Exception('RedGIFs said ${r.statusCode}');
    _token = jsonDecode(r.body)['token'] as String;
    var until = DateTime.now().add(const Duration(hours: 12));
    try {
      final p = _token!.split('.')[1];
      final exp = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(p))))['exp'] as int;
      until = DateTime.fromMillisecondsSinceEpoch(exp * 1000).subtract(const Duration(minutes: 5));
    } catch (_) {}
    _tokenUntil = until;
    return _token!;
  }

  /// Direct playable mp4 (or the url as is when it's already direct).
  static Future<String> playable(String url) async {
    if (_cache[url] != null) return _cache[url]!;
    String out = url;
    final rg = redgifsId(url);
    final st = streamableId(url);
    if (rg != null && !url.contains('.mp4')) {
      for (final fresh in [false, true]) {
        final t = await _redgifsToken(fresh: fresh);
        final r = await client.get(Uri.parse('https://api.redgifs.com/v2/gifs/$rg'), headers: {'User-Agent': ua, 'Authorization': 'Bearer $t'});
        if (r.statusCode == 401 && !fresh) continue;
        if (r.statusCode != 200) throw Exception(r.statusCode == 404 || r.statusCode == 410 ? 'Gone from RedGIFs' : 'RedGIFs said ${r.statusCode}');
        final urls = jsonDecode(r.body)['gif']['urls'] as Map;
        out = (urls['hd'] ?? urls['sd']) as String;
        break;
      }
    } else if (st != null) {
      final r = await client.get(Uri.parse('https://api.streamable.com/videos/$st'), headers: {'User-Agent': ua});
      if (r.statusCode != 200) throw Exception('Streamable said ${r.statusCode}');
      final f = jsonDecode(r.body)['files'] as Map;
      var u = (f['mp4'] ?? f['mp4-mobile'])['url'] as String;
      if (u.startsWith('//')) u = 'https:$u';
      out = u;
    }
    _cache[url] = out;
    return out;
  }
}
