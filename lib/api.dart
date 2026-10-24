import 'dart:convert';
import 'package:http/http.dart' as http;
import 'archive.dart';
import 'auth.dart';
import 'db.dart';
import 'models.dart';

class Api {
  static Future<Map<String, dynamic>> get(String path, [Map<String, String>? q]) async {
    final a = Auth.i;
    for (var attempt = 0; attempt < 2; attempt++) {
      final t = await a.token(force: attempt == 1);
      final r = await http.get(Uri.https('oauth.reddit.com', path, {'raw_json': '1', ...?q}),
          headers: {'Authorization': 'bearer $t', 'User-Agent': a.userAgent});
      if (r.statusCode == 401 && attempt == 0) continue;
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode} for $path');
      return jsonDecode(r.body);
    }
    throw Exception('Unauthorized');
  }

  /// source examples: "submitted", "saved", "upvoted", "r/pics"
  static String pathFor(String source) {
    final parts = source.split('|');
    final sort = (parts.length > 1 ? parts[1] : 'new').split(':')[0];
    if (source.startsWith('home')) return '/$sort';
    if (source.startsWith('r/')) return '/${parts[0]}/${sort == 'best' ? 'hot' : sort}';
    if (source.startsWith('u/')) return '/user/${parts[0].substring(2)}/submitted';
    return '/user/${Auth.i.username}/$source';
  }

  static String? _timeFor(String source) {
    final parts = source.split('|');
    if (parts.length < 2) return null;
    final st = parts[1].split(':');
    return st.length > 1 ? st[1] : null;
  }

  /// Fetch next page for source, cache it, return number of new posts. Returns -1 if done.
  static Future<int> fetchMore(String source, {bool fromStart = false}) async {
    if (isDeep(source)) return Archive.fetchMore(source, fromStart: fromStart);
    final (after, done) = await Db.cursor(source);
    if (done && !fromStart) return -1;
    final j = await get(pathFor(source), {
      'limit': '100',
      if (!fromStart && after != null) 'after': after,
      if (source == 'saved') 'type': 'links',
      if (source.startsWith('u/') && source.contains('|')) 'sort': source.split('|')[1].split(':')[0],
      if (_timeFor(source) != null) 't': _timeFor(source)!,
    });
    final children = (j['data']['children'] as List);
    final posts = children
        .where((c) => c['kind'] == 't3')
        .map((c) => Post.fromJson(Map<String, dynamic>.from(c['data'])))
        .whereType<Post>()
        .toList();
    await Db.savePosts(source, posts);
    if (!fromStart) await Db.setCursor(source, j['data']['after']);
    if (fromStart && after == null && !done) await Db.setCursor(source, j['data']['after']);
    return posts.length;
  }
}
