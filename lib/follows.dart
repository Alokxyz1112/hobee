import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'db.dart';

/// Followed subreddits and users, grouped into local profiles (no Reddit login).

enum FollowKind { sub, user }

class Follow {
  final FollowKind kind;
  final String name;
  const Follow(this.kind, this.name);

  String get key => '${kind == FollowKind.sub ? 'r' : 'u'}/${name.toLowerCase()}';
  String get label => '${kind == FollowKind.sub ? 'r' : 'u'}/$name';

  @override
  bool operator ==(Object o) => o is Follow && o.key == key;
  @override
  int get hashCode => key.hashCode;
  @override
  String toString() => label;
}

class ImportResult {
  final List<Follow> follows; // unique (case-insensitive), first-seen order
  final List<String> skipped; // tokens that weren't a subreddit or user
  const ImportResult(this.follows, this.skipped);
  int get subs => follows.where((f) => f.kind == FollowKind.sub).length;
  int get users => follows.where((f) => f.kind == FollowKind.user).length;
}

final _subName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_]{1,20}$');
final _userName = RegExp(r'^[A-Za-z0-9_-]{3,20}$');

/// Parses pasted text or a .txt/.csv file. Accepts, one or many per line, comma- or space-separated:
/// r/name, /r/name, u/name, /u/name, /user/name, reddit / old.reddit URLs, multireddit links
/// (reddit.com/r/a+b+c), u_name entries (how followed users show in /subreddits/mine), bare names
/// (taken as subreddits), and CSV with a `subreddit` column (Reddit's data export).
ImportResult parseFollowList(String text) {
  final out = <Follow>[];
  final seen = <String>{};
  final skipped = <String>[];
  void add(Follow f) {
    if (seen.add(f.key)) out.add(f);
  }

  void name(String raw, {bool user = false}) {
    final n = raw.trim();
    if (n.isEmpty) return;
    final lower = n.toLowerCase();
    if (!user && lower.startsWith('u_') && n.length > 2) {
      final u = n.substring(2);
      _userName.hasMatch(u) ? add(Follow(FollowKind.user, u)) : skipped.add(raw);
    } else if (user) {
      _userName.hasMatch(n) ? add(Follow(FollowKind.user, n)) : skipped.add(raw);
    } else {
      _subName.hasMatch(n) ? add(Follow(FollowKind.sub, n)) : skipped.add(raw);
    }
  }

  final lines = text.replaceAll('\r', '').split('\n');
  // CSV with a header row that names a `subreddit` column (e.g. subscribed_subreddits.csv).
  final header = lines.isEmpty ? <String>[] : _csvCells(lines.first).map((c) => c.toLowerCase()).toList();
  final col = header.indexOf('subreddit');
  if (col >= 0) {
    for (final l in lines.skip(1)) {
      final cells = _csvCells(l);
      if (col < cells.length) name(cells[col].replaceFirst(RegExp(r'^/?r/', caseSensitive: false), ''));
    }
    return ImportResult(out, skipped);
  }

  for (final line in lines) {
    for (var tok in line.split(RegExp(r'[\s,;]+'))) {
      tok = tok.trim().replaceAll(RegExp(r'''^["'<(\[]+|["'>)\].!?]+$'''), '');
      if (tok.isEmpty) continue;
      // Strip scheme/host of reddit URLs (www., old., new., np., or none).
      final path = tok.replaceFirst(RegExp(r'^(?:https?://)?(?:[a-z0-9-]+\.)*reddit\.com', caseSensitive: false), '');
      final noQuery = path.split(RegExp(r'[?#]')).first;
      final m = RegExp(r'^/?(r|u|user)/([^/]+)', caseSensitive: false).firstMatch(noQuery);
      if (m != null) {
        final isUser = m.group(1)!.toLowerCase() != 'r';
        for (final part in m.group(2)!.split('+')) {
          name(part, user: isUser);
        }
        continue;
      }
      if (path != tok) {
        skipped.add(tok); // a reddit.com link that isn't a subreddit or user page
        continue;
      }
      name(noQuery.replaceAll(RegExp(r'/+$'), ''));
    }
  }
  return ImportResult(out, skipped);
}

/// Minimal CSV cell split (quoted cells may contain commas; doubled quotes unescape).
List<String> _csvCells(String line) {
  final cells = <String>[];
  final b = StringBuffer();
  var q = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (q) {
      if (c == '"' && i + 1 < line.length && line[i + 1] == '"') {
        b.write('"');
        i++;
      } else if (c == '"') {
        q = false;
      } else {
        b.write(c);
      }
    } else if (c == '"') {
      q = true;
    } else if (c == ',') {
      cells.add(b.toString().trim());
      b.clear();
    } else {
      b.write(c);
    }
  }
  cells.add(b.toString().trim());
  return cells;
}

/// Export as plain text (one r/name or u/name per line) or CSV (kind,name).
String exportFollows(List<Follow> fs, {bool csv = false}) => csv
    ? ['kind,name', for (final f in fs) '${f.kind == FollowKind.sub ? 'subreddit' : 'user'},${f.name}'].join('\n')
    : [for (final f in fs) f.label].join('\n');

class Profile {
  final int id;
  final String name;
  const Profile(this.id, this.name);
}

/// SQLite storage for profiles and their follows (tables created in Db v6).
class FollowStore {
  /// Profile the Following feed shows; persisted.
  static final active = ValueNotifier<int?>(null);
  /// Bumps whenever profiles or follows change, so screens can reload.
  static final version = ValueNotifier<int>(0);

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final ps = await profiles();
    final saved = sp.getInt('followProfile');
    active.value = ps.any((p) => p.id == saved) ? saved : ps.first.id;
  }

  static Future<void> setActive(int id) async {
    active.value = id;
    (await SharedPreferences.getInstance()).setInt('followProfile', id);
  }

  /// All profiles, oldest first; creates "Main" when there are none.
  static Future<List<Profile>> profiles() async {
    final d = await Db.db;
    var rows = await d.query('profiles', orderBy: 'id');
    if (rows.isEmpty) {
      await d.insert('profiles', {'name': 'Main', 'created': DateTime.now().millisecondsSinceEpoch});
      rows = await d.query('profiles', orderBy: 'id');
    }
    return [for (final r in rows) Profile(r['id'] as int, r['name'] as String)];
  }

  /// New profile; returns its id. Names are unique (case-insensitive).
  static Future<int> createProfile(String name) async {
    final d = await Db.db;
    final id = await d.insert('profiles', {'name': name.trim(), 'created': DateTime.now().millisecondsSinceEpoch});
    version.value++;
    return id;
  }

  static Future<void> renameProfile(int id, String name) async {
    final d = await Db.db;
    await d.update('profiles', {'name': name.trim()}, where: 'id=?', whereArgs: [id]);
    version.value++;
  }

  /// Deletes a profile and only its follows. The last profile can't be deleted.
  static Future<bool> deleteProfile(int id) async {
    final d = await Db.db;
    final n = Sqflite.firstIntValue(await d.rawQuery('SELECT COUNT(*) FROM profiles')) ?? 0;
    if (n <= 1) return false;
    await d.transaction((t) async {
      await t.delete('follows', where: 'profile=?', whereArgs: [id]);
      await t.delete('profiles', where: 'id=?', whereArgs: [id]);
    });
    if (active.value == id) active.value = (await profiles()).first.id;
    version.value++;
    return true;
  }

  static Future<List<Follow>> follows(int profile) async {
    final d = await Db.db;
    final rows = await d.query('follows', where: 'profile=?', whereArgs: [profile], orderBy: 'kind, name COLLATE NOCASE');
    return [for (final r in rows) Follow(r['kind'] == 'u' ? FollowKind.user : FollowKind.sub, r['name'] as String)];
  }

  /// Adds follows to a profile, skipping ones it already has (case-insensitive). Returns how many were new.
  static Future<int> add(int profile, List<Follow> fs) async {
    final d = await Db.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    var added = 0;
    await d.transaction((t) async {
      Future<int> count() async => Sqflite.firstIntValue(await t.rawQuery('SELECT COUNT(*) FROM follows WHERE profile=?', [profile])) ?? 0;
      final before = await count();
      final b = t.batch();
      for (final f in fs) {
        b.insert('follows', {'profile': profile, 'kind': f.kind == FollowKind.sub ? 'r' : 'u', 'name': f.name, 'added': now},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await b.commit(noResult: true);
      added = await count() - before;
    });
    version.value++;
    return added;
  }

  static Future<void> remove(int profile, Follow f) async {
    final d = await Db.db;
    await d.delete('follows', where: 'profile=? AND kind=? AND name=? COLLATE NOCASE', whereArgs: [profile, f.kind == FollowKind.sub ? 'r' : 'u', f.name]);
    version.value++;
  }
}
