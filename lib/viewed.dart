import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import 'db.dart';

/// Authors whose profile was opened from subreddit results. Global across subreddits, stored in SQLite.
class Viewed {
  static final names = ValueNotifier<Set<String>>(<String>{});
  static final hide = ValueNotifier<bool>(true);
  static String? lastMarked;

  static bool has(String n) => names.value.contains(n.toLowerCase());

  static Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      hide.value = sp.getBool('hideViewed') ?? true;
      hide.addListener(() => sp.setBool('hideViewed', hide.value));
      final db = await Db.db;
      await _table();
      final rows = await db.query('viewed_users', columns: ['author']);
      names.value = {for (final r in rows) (r['author'] as String)};
    } catch (_) {}
  }

  static Future<void> _table() async =>
      (await Db.db).execute('CREATE TABLE IF NOT EXISTS viewed_users(author TEXT PRIMARY KEY, at INTEGER)');

  static void mark(String n) {
    final k = n.toLowerCase();
    lastMarked = n;
    if (names.value.contains(k)) return;
    names.value = {...names.value, k};
    _write(() async => (await Db.db).insert('viewed_users', {'author': k, 'at': DateTime.now().millisecondsSinceEpoch ~/ 1000},
        conflictAlgorithm: ConflictAlgorithm.replace));
  }

  static void unmark(String n) {
    final k = n.toLowerCase();
    names.value = {...names.value}..remove(k);
    _write(() async => (await Db.db).delete('viewed_users', where: 'author = ?', whereArgs: [k]));
  }

  static void clear() {
    names.value = <String>{};
    _write(() async => (await Db.db).delete('viewed_users'));
  }

  static void _write(Future<void> Function() f) async {
    try {
      await _table();
      await f();
    } catch (_) {}
  }
}

/// Pure: posts left after hiding viewed authors.
List<T> withoutViewed<T>(List<T> items, String Function(T) author, Set<String> viewed, bool hide) =>
    !hide || viewed.isEmpty ? items : items.where((x) => !viewed.contains(author(x).toLowerCase())).toList();
