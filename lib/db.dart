import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'models.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart' show compute;

List<Post> _decodeAll(List<String> js) => js.map((j) => Post.fromJson(jsonDecode(j))).whereType<Post>().toList();

class Db {
  static Database? _db;
  static Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await openDatabase(p.join(await getDatabasesPath(), 'hobee.db'), version: 7, onUpgrade: (db, o, n) async {
      if (o < 2) await _v2(db);
      if (o < 3) await _v3(db);
      if (o < 4) await _v4(db);
      if (o < 5) await _v5(db);
      if (o < 6) await _v6(db);
      if (o < 7) await _v7(db);
    }, onCreate: (db, v) async {
      await db.execute('CREATE TABLE posts(source TEXT, id TEXT, created INTEGER, json TEXT, PRIMARY KEY(source,id))');
      await db.execute('CREATE INDEX idx_src_created ON posts(source, created)');
      await db.execute('CREATE TABLE cursors(source TEXT PRIMARY KEY, after TEXT, done INTEGER)');
      await _v2(db);
      await _v3(db);
      await _v4(db);
      await _v5(db);
      await _v6(db);
    });
    return _db!;
  }

  /// v7: Following posts saved before trimming: drop the fields the app never reads (see [slimPost]).
  static Future<void> _v7(Database db) async {
    var last = 0;
    while (true) {
      final rows = await db.rawQuery("SELECT rowid AS r, json FROM posts WHERE source LIKE 'fol:%' AND rowid > ? ORDER BY rowid LIMIT 500", [last]);
      if (rows.isEmpty) break;
      last = rows.last['r'] as int;
      final b = db.batch();
      for (final r in rows) {
        try {
          final slim = jsonEncode(slimPost(jsonDecode(r['json'] as String) as Map<String, dynamic>));
          b.rawUpdate('UPDATE posts SET json=? WHERE rowid=?', [slim, r['r']]);
        } catch (_) {}
      }
      await b.commit(noResult: true);
    }
  }

  /// v6: local profiles and the subreddits/users each one follows (Following feed, no login).
  static Future<void> _v6(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS profiles(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE COLLATE NOCASE, created INTEGER)');
    await db.execute('CREATE TABLE IF NOT EXISTS follows(profile INTEGER, kind TEXT, name TEXT COLLATE NOCASE, added INTEGER, PRIMARY KEY(profile, kind, name))');
  }

  static Future<void> _v2(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS media_check(url TEXT PRIMARY KEY, result TEXT, checked INTEGER)');
  }

  static Future<void> _v3(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS phash(url TEXT PRIMARY KEY, hash INTEGER)');
  }

  static Future<void> _v4(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS deep_history(key TEXT PRIMARY KEY, avatar TEXT, posts INTEGER, last INTEGER, seconds INTEGER DEFAULT 0)');
    await db.execute('CREATE TABLE IF NOT EXISTS interest(kind TEXT, key TEXT, score REAL, updated INTEGER, PRIMARY KEY(kind, key))');
    await db.execute('CREATE TABLE IF NOT EXISTS sub_authors(sub TEXT, author TEXT, n INTEGER, fetched INTEGER, PRIMARY KEY(sub, author))');
  }

  static Future<void> _v5(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS acct_meta(author TEXT PRIMARY KEY, post INTEGER, comment INTEGER, total INTEGER, nsfw INTEGER, fetched INTEGER)');
    await db.execute('CREATE TABLE IF NOT EXISTS author_mix(author TEXT, sub TEXT, n INTEGER, img INTEGER, vid INTEGER, gal INTEGER, txt INTEGER, nsfw INTEGER, titles TEXT, fetched INTEGER, PRIMARY KEY(author, sub))');
    await db.execute('CREATE TABLE IF NOT EXISTS sub_meta(sub TEXT PRIMARY KEY, nsfw REAL, fetched INTEGER)');
  }

  /// Rows per database read. One query result is copied whole across the platform channel, so a big feed
  /// read at once can run the Android side out of memory; reading it in chunks keeps each copy small.
  static int chunkRows = 1000;

  /// Posts matching [where], newest first, read [chunkRows] at a time and decoded off the UI thread.
  static Future<List<Post>> _loadChunked(String where, List<Object?> args, {bool onePerId = false}) async {
    final d = await db;
    final out = <Post>[];
    final seen = <String>{};
    var last = 0;
    while (true) {
      final rows = await d.rawQuery('SELECT rowid AS r, json FROM posts WHERE $where AND rowid > ? ORDER BY rowid LIMIT ?',
          [...args, last, chunkRows]);
      if (rows.isEmpty) break;
      last = rows.last['r'] as int;
      final raw = [for (final r in rows) r['json'] as String];
      final posts = raw.length > 150 ? await compute(_decodeAll, raw) : _decodeAll(raw);
      for (final p in posts) {
        if (!onePerId || seen.add(p.id)) out.add(p);
      }
      if (rows.length < chunkRows) break;
    }
    out.sort((a, b) => b.created.compareTo(a.created));
    return out;
  }

  /// Every cached post once (by id), newest first. Decoded off the UI thread.
  static Future<List<Post>> loadEverything() => _loadChunked('1=1', const [], onePerId: true);

  static Future<int> count(String source) async {
    final d = await db;
    return Sqflite.firstIntValue(await d.rawQuery('SELECT COUNT(*) FROM posts WHERE source=?', [source])) ?? 0;
  }

  /// Perceptual hashes by thumbnail URL (null value = could not hash).
  static Future<Map<String, int?>> hashes(List<String> urls) async {
    final d = await db;
    final out = <String, int?>{};
    for (var i = 0; i < urls.length; i += 500) {
      final chunk = urls.sublist(i, i + 500 > urls.length ? urls.length : i + 500);
      final rows = await d.query('phash', where: 'url IN (${List.filled(chunk.length, '?').join(',')})', whereArgs: chunk);
      for (final r in rows) {
        out[r['url'] as String] = r['hash'] as int?;
      }
    }
    return out;
  }

  static Future<void> setHash(String url, int? hash) async {
    final d = await db;
    await d.insert('phash', {'url': url, 'hash': hash}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Cached media resolution: '' = gone, otherwise working URL. null = not checked (or stale after 14 days).
  static Future<String?> mediaStatus(String url) async {
    final d = await db;
    final r = await d.query('media_check', where: 'url=?', whereArgs: [url]);
    if (r.isEmpty) return null;
    final age = DateTime.now().millisecondsSinceEpoch - (r.first['checked'] as int);
    if (age > const Duration(days: 14).inMilliseconds) return null;
    return r.first['result'] as String?;
  }

  static Future<void> setMediaStatus(String url, String result) async {
    final d = await db;
    await d.insert('media_check', {'url': url, 'result': result, 'checked': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Set<String>> liveIds(String source) async {
    final d = await db;
    final rows = await d.rawQuery('SELECT id FROM posts WHERE source=? AND instr(json, ?) > 0', [source, '"_hobee_live":true']);
    return {for (final r in rows) r['id'] as String};
  }

  static Future<Set<String>> thinIds(String source) async {
    final d = await db;
    final rows = await d.rawQuery('SELECT id FROM posts WHERE source=? AND instr(json, ?) > 0', [source, '"_hobee_thin":true']);
    return {for (final r in rows) r['id'] as String};
  }

  static Future<void> savePosts(String source, List<Post> posts) async {
    final d = await db;
    final b = d.batch();
    for (final x in posts) {
      b.insert('posts', {'source': source, 'id': x.id, 'created': x.created, 'json': x.encode()},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await b.commit(noResult: true);
  }

  /// Posts of [source], newest first (read in chunks; big feeds are decoded off the UI thread).
  static Future<List<Post>> load(String source) => _loadChunked('source=?', [source]);

  static Future<(String?, bool)> cursor(String source) async {
    final d = await db;
    final r = await d.query('cursors', where: 'source=?', whereArgs: [source]);
    if (r.isEmpty) return (null, false);
    return (r.first['after'] as String?, (r.first['done'] as int) == 1);
  }

  static Future<void> setCursor(String source, String? after) async {
    final d = await db;
    await d.insert('cursors', {'source': source, 'after': after, 'done': after == null ? 1 : 0},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> clearAll() async {
    final d = await db;
    await d.delete('posts');
    await d.delete('cursors');
    await d.delete('media_check');
    await d.delete('phash');
    await d.delete('sub_authors');
  }
}

