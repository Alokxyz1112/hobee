import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'models.dart';
import 'dart:convert';

class Db {
  static Database? _db;
  static Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await openDatabase(p.join(await getDatabasesPath(), 'hobee.db'), version: 3, onUpgrade: (db, o, n) async {
      if (o < 2) await _v2(db);
      if (o < 3) await _v3(db);
    }, onCreate: (db, v) async {
      await db.execute('CREATE TABLE posts(source TEXT, id TEXT, created INTEGER, json TEXT, PRIMARY KEY(source,id))');
      await db.execute('CREATE INDEX idx_src_created ON posts(source, created)');
      await db.execute('CREATE TABLE cursors(source TEXT PRIMARY KEY, after TEXT, done INTEGER)');
      await _v2(db);
      await _v3(db);
    });
    return _db!;
  }

  static Future<void> _v2(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS media_check(url TEXT PRIMARY KEY, result TEXT, checked INTEGER)');
  }

  static Future<void> _v3(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS phash(url TEXT PRIMARY KEY, hash INTEGER)');
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
    final rows = await d.query('posts', columns: ['id', 'json'], where: 'source=?', whereArgs: [source]);
    return {for (final r in rows) if ((r['json'] as String).contains('"_hobee_live":true')) r['id'] as String};
  }

  static Future<Set<String>> thinIds(String source) async {
    final d = await db;
    final rows = await d.query('posts', columns: ['id', 'json'], where: 'source=?', whereArgs: [source]);
    return {for (final r in rows) if ((r['json'] as String).contains('"_hobee_thin":true')) r['id'] as String};
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

  static Future<List<Post>> load(String source) async {
    final d = await db;
    final rows = await d.query('posts', where: 'source=?', whereArgs: [source], orderBy: 'created DESC');
    return rows.map((r) => Post.fromJson(jsonDecode(r['json'] as String))).whereType<Post>().toList();
  }

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
  }
}
