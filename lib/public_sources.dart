import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// No-login public sources for a user's submitted posts: Reddit RSS and Redlib (HTML).
/// Each returns reddit-JSON-shaped maps so Post.fromJson / parseMedia handle them.
class PublicPage {
  final List<Map<String, dynamic>> rows;
  final String? after; // t3_ fullname for the next page, null = end
  final String via; // e.g. 'redlib.ducks.party'
  PublicPage(this.rows, this.after, this.via);
}

class PublicFail implements Exception {
  final String why, detail;
  PublicFail(this.why, this.detail);
  @override
  String toString() => why;
}

class RedlibConfig {
  /// Official list: github.com/redlib-org/redlib-instances (tested 2026-10-24; redlib.ducks.party served full HTML).
  static const defaults = [
    'https://redlib.ducks.party',
    'https://redlib.privacyredirect.com',
    'https://red.artemislena.eu',
    'https://redlib.privadency.com',
    'https://redlib.catsarch.com',
    'https://safereddit.com',
  ];
  static final preferred = ValueNotifier<String>(defaults.first);
  static final enabled = ValueNotifier<bool>(true);
  static final rssEnabled = ValueNotifier<bool>(true);

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    preferred.value = sp.getString('redlibInstance') ?? defaults.first;
    enabled.value = sp.getBool('redlibOn') ?? true;
    rssEnabled.value = sp.getBool('rssOn') ?? true;
  }

  static Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('redlibInstance', preferred.value);
    await sp.setBool('redlibOn', enabled.value);
    await sp.setBool('rssOn', rssEnabled.value);
  }

  static List<String> get order {
    final p = preferred.value.replaceAll(RegExp(r'/+$'), '');
    return [p, ...defaults.where((d) => d != p)];
  }
}

String _snip(String b) {
  final t = b.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 300 ? '${t.substring(0, 300)}…' : t;
}

String _unhtml(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#32;', ' ')
    .replaceAll('&#38;', '&')
    .replaceAll('&amp;', '&');

Future<http.Response> _get(Uri u, String ua, String accept) async {
  try {
    return await http.get(u, headers: {'User-Agent': ua, 'Accept': accept}).timeout(const Duration(seconds: 20));
  } on TimeoutException {
    throw PublicFail('timed out', 'No response in 20 s from ${u.host}');
  } catch (e) {
    throw PublicFail('network error', '$e');
  }
}

void _check(http.Response r, Uri u) {
  if (r.statusCode == 200) return;
  final d = 'HTTP ${r.statusCode} from $u\n${_snip(r.body)}';
  if (r.statusCode == 429) throw PublicFail('rate-limited (HTTP 429)', d);
  throw PublicFail('unavailable (HTTP ${r.statusCode})', d);
}

/// Fill url / thumbnail / is_gallery / post_hint from a media link.
void _media(Map<String, dynamic> d, String? link, String? thumb) {
  if (thumb != null && thumb.isNotEmpty) {
    d['thumbnail'] = thumb;
    d['preview'] = {
      'images': [
        {'source': {'url': thumb}, 'resolutions': []}
      ]
    };
  }
  if (link == null) return;
  d['url'] = link;
  if (link.contains('/gallery/')) d['is_gallery'] = true;
  if (link.contains('i.redd.it') || RegExp(r'\.(jpe?g|png|webp)(\?|$)').hasMatch(link)) d['post_hint'] = 'image';
}

class RedditRss {
  /// https://www.reddit.com/user/NAME/submitted/.rss?limit=100&after=t3_x (Atom). 200 from the box; 429 on bursts.
  static Future<PublicPage> page(String name, String? after, String ua) async {
    final u = Uri.https('www.reddit.com', '/user/$name/submitted/.rss', {'limit': '100', 'sort': 'new', 'after': ?after});
    final r = await _get(u, ua, 'application/atom+xml');
    _check(r, u);
    final body = r.body;
    if (!body.contains('<feed')) throw PublicFail('unexpected response (not Atom)', 'from $u\n${_snip(body)}');
    return parse(body, name);
  }

  static PublicPage parse(String body, String name) {
    final rows = <Map<String, dynamic>>[];
    for (final e in body.split('<entry>').skip(1)) {
      final id = RegExp(r'<id>t3_([a-z0-9]+)</id>').firstMatch(e)?.group(1);
      if (id == null) continue;
      final perm = RegExp(r'<link href="https://www\.reddit\.com(/r/[^"]+)"').firstMatch(e)?.group(1) ?? '';
      final sub = RegExp(r'^/r/([^/]+)/').firstMatch(perm)?.group(1) ?? '';
      final title = _unhtml(RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(e)?.group(1) ?? '');
      final pub = RegExp(r'<published>([^<]+)</published>').firstMatch(e)?.group(1);
      final author = RegExp(r'<name>/u/([^<]+)</name>').firstMatch(e)?.group(1) ?? name;
      final content = _unhtml(RegExp(r'<content[^>]*>(.*?)</content>', dotAll: true).firstMatch(e)?.group(1) ?? '');
      final link = RegExp(r'<a href="([^"]+)">\[link\]</a>').firstMatch(content)?.group(1);
      final thumb = _unhtml(RegExp(r'<media:thumbnail url="([^"]+)"').firstMatch(e)?.group(1) ?? '');
      final d = <String, dynamic>{
        'id': id, 'name': 't3_$id', 'title': title, 'subreddit': sub, 'author': author, 'permalink': perm,
        'created_utc': pub == null ? 0 : (DateTime.tryParse(pub)?.millisecondsSinceEpoch ?? 0) ~/ 1000,
      };
      _media(d, link == null || link.contains('/comments/') ? null : link, thumb);
      rows.add(d);
    }
    return PublicPage(rows, rows.length >= 25 ? rows.last['name'] as String : null, 'reddit.com RSS');
  }
}

class Redlib {
  static String _abs(String base, String p) {
    p = _unhtml(p);
    if (p.startsWith('/img/')) return 'https://i.redd.it/${p.substring(5)}';
    if (p.startsWith('/preview/pre/')) return 'https://preview.redd.it/${p.substring(13)}';
    if (p.startsWith('/preview/external-pre/')) return 'https://external-preview.redd.it/${p.substring(22)}';
    final v = RegExp(r'^/vid/([A-Za-z0-9]+)/').firstMatch(p);
    if (v != null) return 'https://v.redd.it/${v.group(1)}';
    final t = RegExp(r'^/thumb/([a-z])/(.+)$').firstMatch(p);
    if (t != null) return 'https://${t.group(1)}.thumbs.redditmedia.com/${t.group(2)}';
    return p.startsWith('http') ? p : '$base$p';
  }

  static int _date(String s) {
    // "Oct 09 2026, 16:14:29 UTC"
    const mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final m = RegExp(r'(\w{3}) (\d+) (\d{4}), (\d+):(\d+):(\d+)').firstMatch(s);
    if (m == null) return 0;
    final mi = mon.indexOf(m.group(1)!) + 1;
    return DateTime.utc(int.parse(m.group(3)!), mi, int.parse(m.group(2)!), int.parse(m.group(4)!), int.parse(m.group(5)!),
                int.parse(m.group(6)!))
            .millisecondsSinceEpoch ~/
        1000;
  }

  static PublicPage parse(String base, String html, String name) {
    final rows = <Map<String, dynamic>>[];
    final host = Uri.parse(base).host;
    for (final b in html.split(RegExp(r'<div class="post(?: stickied)?" id="')).skip(1)) {
      final id = RegExp(r'^([a-z0-9]+)"').firstMatch(b)?.group(1);
      if (id == null) continue;
      final tm = RegExp(r'<h2 class="post_title">.*?<a href="(/r/[^"]+)">(.*?)</a>', dotAll: true).firstMatch(b);
      if (tm == null) continue;
      final perm = _unhtml(tm.group(1)!);
      final sub = RegExp(r'^/r/([^/]+)/').firstMatch(perm)?.group(1) ?? '';
      final author = RegExp(r'class="post_author[^"]*" href="/u/([^"]+)"').firstMatch(b)?.group(1) ?? name;
      final created = _date(RegExp(r'class="created" title="([^"]+)"').firstMatch(b)?.group(1) ?? '');
      final d = <String, dynamic>{
        'id': id, 'name': 't3_$id', 'title': _unhtml(tm.group(2)!.replaceAll(RegExp(r'<[^>]+>'), '').trim()),
        'subreddit': sub, 'author': author, 'permalink': perm, 'created_utc': created,
      };
      final mediaEnd = b.indexOf('class="post_score"');
      final mb = mediaEnd > 0 ? b.substring(0, mediaEnd) : b;
      final vid = RegExp(r'src="(/vid/[^"]+)"').firstMatch(mb)?.group(1);
      final poster = RegExp(r'poster="([^"]+)"').firstMatch(mb)?.group(1);
      final img = RegExp(r'href="(/img/[^"]+|/preview/pre/[^"]+)" class="post_media_image').firstMatch(mb)?.group(1) ??
          RegExp(r'src="(/img/[^"]+)"').firstMatch(mb)?.group(1);
      final thumb = RegExp(r'src="(/thumb/[^"]+|/preview/[^"]+)"').firstMatch(mb)?.group(1);
      final gallery = mb.contains('<span>gallery</span>');
      if (vid != null) {
        _media(d, _abs(base, vid), poster == null ? null : _abs(base, poster));
      } else if (img != null) {
        final u = _abs(base, img);
        _media(d, u, u);
      } else if (gallery) {
        _media(d, 'https://www.reddit.com/gallery/$id', thumb == null ? null : _abs(base, thumb));
      } else if (thumb != null) {
        _media(d, null, _abs(base, thumb));
      }
      rows.add(d);
    }
    final next = RegExp(r'href="\?[^"]*after=(t3_[a-z0-9]+)"').firstMatch(html)?.group(1);
    return PublicPage(rows, next, host);
  }

  /// Tries the preferred instance, then the next ones, until one returns a real listing.
  static Future<PublicPage> page(String name, String? after, String ua) async {
    final fails = <String>[];
    for (final base in RedlibConfig.order) {
      final u = Uri.parse('$base/user/$name/submitted').replace(queryParameters: {'sort': 'new', 'after': ?after});
      try {
        final r = await _get(u, ua, 'text/html');
        _check(r, u);
        if (!r.body.contains('class="post') && !r.body.contains('id="posts"')) {
          throw PublicFail('no listing (challenge/blocked page)', 'from $u\n${_snip(r.body)}');
        }
        final p = parse(base, r.body, name);
        if (p.rows.isEmpty && after == null && !r.body.contains('id="posts"')) {
          throw PublicFail('empty page', 'from $u');
        }
        return p;
      } on PublicFail catch (e) {
        fails.add('${Uri.parse(base).host}: ${e.why}');
      }
    }
    throw PublicFail('all instances failed', fails.join('\n'));
  }
}

