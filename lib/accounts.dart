import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'archive.dart';
import 'db.dart';
import 'dedupe.dart';
import 'filters.dart';
import 'find.dart';
import 'models.dart';
import 'nav.dart';

/// One Deep Search account ("NAME" or "NAME@SUB").
class DeepAccount {
  final String key;
  final String? avatar;
  final int posts, last, seconds;
  DeepAccount(this.key, this.avatar, this.posts, this.last, this.seconds);
  String get user => key.split('@').first;
  String? get sub => key.contains('@') ? key.split('@')[1] : null;
  String get label => 'u/${key.replaceFirst('@', ' · r/')}';
}

String ago(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  return '${(d.inDays / 30).floor()}mo ago';
}

/// Deep Search history in SQLite, most recent first.
class DeepHistory {
  static final changed = ValueNotifier<int>(0);
  static List<DeepAccount> items = [];
  static final Set<String> _avatarTried = {};

  static Future<void> load() async {
    final d = await Db.db;
    var rows = await d.query('deep_history', orderBy: 'last DESC');
    if (rows.isEmpty) {
      // One-time move of the old recents list.
      final old = Recents.get(Recents.deep);
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < old.length; i++) {
        await d.insert('deep_history', {'key': old[i], 'posts': await Db.count('deep:${old[i]}'), 'last': now - i * 1000, 'seconds': 0},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      rows = await d.query('deep_history', orderBy: 'last DESC');
    }
    items = [
      for (final r in rows)
        DeepAccount(r['key'] as String, r['avatar'] as String?, (r['posts'] as int?) ?? 0, (r['last'] as int?) ?? 0, (r['seconds'] as int?) ?? 0)
    ];
    changed.value++;
  }

  static DeepAccount? find(String key) => items.where((a) => a.key == key).firstOrNull;

  /// Called on every Deep Search start.
  static Future<void> touch(String key) async {
    final d = await Db.db;
    final n = await Db.count('deep:$key');
    final upd = await d.update('deep_history', {'last': DateTime.now().millisecondsSinceEpoch, 'posts': n}, where: 'key=?', whereArgs: [key]);
    if (upd == 0) {
      await d.insert('deep_history', {'key': key, 'posts': n, 'last': DateTime.now().millisecondsSinceEpoch, 'seconds': 0});
    }
    await Interest.bump('user', key.split('@').first.toLowerCase(), 3);
    await load();
    _avatar(key);
  }

  static Future<void> _avatar(String key) async {
    final a = find(key);
    if (a == null || a.avatar != null || !_avatarTried.add(key)) return;
    final url = await Archive.avatar(a.user);
    if (url == null) return;
    final d = await Db.db;
    await d.update('deep_history', {'avatar': url}, where: 'key=?', whereArgs: [key]);
    await load();
  }

  /// Time spent on a result plus a fresh post count.
  static Future<void> leave(String key, int seconds) async {
    final d = await Db.db;
    await d.rawUpdate('UPDATE deep_history SET seconds = seconds + ?, posts = ? WHERE key=?', [seconds, await Db.count('deep:$key'), key]);
    if (seconds > 20) await Interest.bump('user', key.split('@').first.toLowerCase(), min(seconds / 60, 5));
    await load();
  }

  static Future<void> remove(String key) async {
    final d = await Db.db;
    await d.delete('deep_history', where: 'key=?', whereArgs: [key]);
    Recents.remove(Recents.deep, key);
    await load();
  }

  static Future<void> clear() async {
    final d = await Db.db;
    await d.delete('deep_history');
    Recents.clear(Recents.deep);
    await load();
  }
}

/// Local interest profile: what gets opened, saved and searched. Scores fade by ~2% a day.
class Interest {
  static Future<void> bump(String kind, String key, double w) async {
    if (key.isEmpty || key == '[deleted]') return;
    final d = await Db.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final r = await d.query('interest', where: 'kind=? AND key=?', whereArgs: [kind, key]);
    var s = w;
    if (r.isNotEmpty) {
      final days = (now - (r.first['updated'] as int)) / 86400000;
      s += (r.first['score'] as num).toDouble() * pow(0.98, days);
    }
    await d.insert('interest', {'kind': kind, 'key': key, 'score': s, 'updated': now}, conflictAlgorithm: ConflictAlgorithm.replace);
    Suggest.invalidate();
  }

  static void opened(Post p) {
    bump('sub', p.subreddit.toLowerCase(), 1);
    bump('author', p.author.toLowerCase(), 0.5);
  }

  static void downloaded(Post p) {
    bump('sub', p.subreddit.toLowerCase(), 3);
    bump('author', p.author.toLowerCase(), 1);
  }

  static Future<Map<String, double>> of(String kind) async {
    final d = await Db.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await d.query('interest', where: 'kind=?', whereArgs: [kind]);
    return {for (final r in rows) r['key'] as String: (r['score'] as num).toDouble() * pow(0.98, (now - (r['updated'] as int)) / 86400000)};
  }
}

/// Recent post mix of one account (saved posts plus Arctic Shift samples).
class Mix {
  int n = 0, img = 0, vid = 0, gal = 0, txt = 0, nsfw = 0;
  final Set<String> subs = {};
  final StringBuffer titles = StringBuffer();
  void addPost(Post p) {
    n++;
    if (p.raw['over_18'] == true) nsfw++;
    if (p.media.isEmpty) {
      txt++;
    } else {
      switch (kindOf(p)) {
        case MediaFilter.videos:
          vid++;
        case MediaFilter.galleries:
          gal++;
        default:
          img++;
      }
    }
    subs.add(p.subreddit.toLowerCase());
    if (titles.length < 4000) titles.write(' ${fold(p.title)}');
  }

  /// A post that was dropped for being marked over_18 (counted, never kept).
  void addHidden() {
    n++;
    nsfw++;
  }
}

class Suggestion {
  final String user, reason;
  final double score;
  final bool nsfwHint; // mostly adult posts or subs, never shown
  final Mix mix;
  Suggestion(this.user, this.score, this.reason, {this.nsfwHint = false, Mix? mix}) : mix = mix ?? Mix();
}

String fmtKarma(int n) {
  String t(double v) => (v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)).replaceFirst(RegExp(r'\.0$'), '');
  if (n >= 1000000) return '${t(n / 1000000)}M';
  if (n >= 1000) return '${t(n / 1000)}K';
  return '$n';
}

class AcctMeta {
  final int? post, comment, total; // null total = couldn't read (blocked, suspended, gone)
  final bool? nsfw;
  final bool suspended;
  final int fetched;
  AcctMeta(this.post, this.comment, this.total, this.nsfw, this.suspended, this.fetched);
}

/// Lazy, cached (24 h) karma + adult-profile lookups for suggested accounts.
class AccountMeta {
  static final Map<String, AcctMeta> _m = {};
  static bool _loaded = false;
  static final List<String> _queue = [];
  static bool _running = false;
  static bool get busy => _running;

  static AcctMeta? of(String user) => _m[user.toLowerCase()];

  static Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final d = await Db.db;
    for (final r in await d.query('acct_meta')) {
      final n = r['nsfw'] as int?;
      _m[r['author'] as String] = AcctMeta(r['post'] as int?, r['comment'] as int?, r['total'] as int?, n == null || n < 0 ? null : n == 1,
          n == 2, r['fetched'] as int);
    }
  }

  static bool _fresh(AcctMeta? m) {
    if (m == null) return false;
    final age = DateTime.now().millisecondsSinceEpoch - m.fetched;
    return age < (m.total == null && !m.suspended ? 3600000 : 86400000);
  }

  /// Queue lookups for these users (in order); runs one at a time.
  static Future<void> ensure(Iterable<String> users) async {
    await _load();
    for (final u in users) {
      final k = u.toLowerCase();
      if (!_fresh(_m[k]) && !_queue.contains(k)) _queue.add(k);
    }
    if (_running || _queue.isEmpty) return;
    _running = true;
    Suggest.bump();
    try {
      while (_queue.isNotEmpty) {
        final u = _queue.removeAt(0);
        final r = await Future.wait([Archive.about(u), Archive.karma(u)]);
        final a = r[0] as ({int post, int comment, int total, bool nsfw, bool suspended})?;
        final k = r[1] as (int, int, int)?;
        final susp = a?.suspended == true && k == null;
        final m = AcctMeta(k?.$1 ?? (susp ? null : a?.post), k?.$2 ?? (susp ? null : a?.comment), k?.$3 ?? (susp ? null : a?.total),
            a == null || susp ? null : a.nsfw, susp, DateTime.now().millisecondsSinceEpoch);
        _m[u] = m;
        final d = await Db.db;
        await d.insert('acct_meta', {'author': u, 'post': m.post, 'comment': m.comment, 'total': m.total, 'nsfw': susp ? 2 : m.nsfw == null ? -1 : (m.nsfw! ? 1 : 0), 'fetched': m.fetched},
            conflictAlgorithm: ConflictAlgorithm.replace);
        Suggest.bump();
      }
    } finally {
      _running = false;
      Suggest.bump();
    }
  }

  /// Pure rule (unit tested): adult or gone accounts are never suggested. No other limits.
  static bool passes(AcctMeta? m, Suggestion s) {
    if (s.nsfwHint || m?.nsfw == true) return false;
    if (m != null && m.suspended) return false;
    return true;
  }

  /// Suggestions that pass, best first. Starts lookups for the top candidates; an account shows once
  /// its profile has been checked, so adult profiles never flash up.
  static List<Suggestion> visible(List<Suggestion> all, {int want = 40}) {
    final out = <Suggestion>[];
    final need = <String>[];
    for (final s in all) {
      if (out.length >= want) break;
      final m = _m[s.user.toLowerCase()];
      if (!_fresh(m) && need.length < want * 2) need.add(s.user);
      if (m == null) continue;
      if (passes(m, s)) out.add(s);
    }
    if (need.isNotEmpty) ensure(need);
    return out;
  }
}

const _skip = {'[deleted]', 'automoderator', 'deleted', ''};

/// Account suggestions from local data plus a few polite Arctic Shift reads (cached 24 h).
class Suggest {
  static final changed = ValueNotifier<int>(0);
  static final Map<String, (int, List<Suggestion>)> _cache = {};
  static DateTime _cooldown = DateTime(2000);
  static bool _fetching = false;
  static bool get fetching => _fetching;
  static Timer? _fetchTimer;

  static void invalidate() => _cache.remove('');

  /// Coalesced repaint signal: meta lookups and fetch passes fire in bursts, listeners rebuild once per 300ms.
  static Timer? _bumpT;
  static void bump() {
    _bumpT ??= Timer(const Duration(milliseconds: 300), () {
      _bumpT = null;
      changed.value++;
    });
  }

  /// Single flight per key, so a burst of listeners shares one computation instead of N full DB decodes.
  static final Map<String, Future<List<Suggestion>>> _inflight = {};
  static int _gen = 0;

  /// All posts snapshot, reused for 2 min (decoding every post per call was the main freeze).
  static (int, List<Post>)? _snap;
  static Future<List<Post>>? _snapF;
  static Future<List<Post>> everything() => _everything();
  static Future<List<Post>> _everything() async {
    final s = _snap;
    if (s != null && DateTime.now().millisecondsSinceEpoch - s.$1 < 120000) return s.$2;
    return _snapF ??= Db.loadEverything().then((a) {
      _snap = (DateTime.now().millisecondsSinceEpoch, a);
      _snapF = null;
      return a;
    }, onError: (e) {
      _snapF = null;
      throw e;
    });
  }

  static void clearCache() {
    _cache.clear();
    _gen++;
  }

  static Future<List<Suggestion>> _once(String key, Future<List<Suggestion>> Function() run) {
    final c = _cache[key];
    if (c != null && DateTime.now().millisecondsSinceEpoch - c.$1 < 600000) return Future.value(c.$2);
    final f = _inflight[key];
    if (f != null) return f;
    final g = _gen;
    final nf = run().then((r) {
      if (g == _gen) _cache[key] = (DateTime.now().millisecondsSinceEpoch, r);
      return r;
    }).whenComplete(() => _inflight.remove(key));
    _inflight[key] = nf;
    return nf;
  }

  /// 'Suggested for you' from everything viewed and searched.
  static Future<List<Suggestion>> forYou() => _once('', _forYou);
  static Future<List<Suggestion>> _forYou() async {
    final all = await _everything();
    final profile = <String, double>{};
    final likeUser = <String, Map<String, int>>{}; // sub -> searched user -> posts
    final searched = {for (final a in DeepHistory.items) a.user.toLowerCase()};
    for (final p in all) {
      final a = p.author.toLowerCase();
      if (!searched.contains(a)) continue;
      final s = p.subreddit.toLowerCase();
      if (s.startsWith('u_')) continue;
      profile[s] = (profile[s] ?? 0) + 1;
      (likeUser[s] ??= {})[p.author] = (likeUser[s]![p.author] ?? 0) + 1;
    }
    // Normalise searched-account subs, then add what was opened or saved.
    final tot = profile.values.fold<double>(0, (a, b) => a + b);
    if (tot > 0) profile.updateAll((k, v) => v / tot * 10);
    (await Interest.of('sub')).forEach((k, v) => profile[k] = (profile[k] ?? 0) + v);
    final userInterest = await Interest.of('author');
    return _rank(all, profile, searched, likeUser, searched, userInterest);
  }

  /// 'Similar accounts' for one user, from their saved posts.
  static Future<List<Suggestion>> similarTo(String user) => _once(user.toLowerCase(), () => _similarTo(user));
  static Future<List<Suggestion>> _similarTo(String user) async {
    final key = user.toLowerCase();
    final all = await _everything();
    final profile = <String, double>{};
    for (final p in all) {
      if (p.author.toLowerCase() != key) continue;
      final s = p.subreddit.toLowerCase();
      if (s.startsWith('u_')) continue;
      profile[s] = (profile[s] ?? 0) + 1;
    }
    return _rank(all, profile, {key}, {for (final s in profile.keys) s: {user: profile[s]!.toInt()}}, {key}, const {});
  }

  static Future<List<Suggestion>> _rank(List<Post> all, Map<String, double> profile, Set<String> exclude,
      Map<String, Map<String, int>> likeUser, Set<String> contentOf, Map<String, double> userInterest) async {
    String tag(String sub) => sub;
    final nsfwSubs = await _nsfwSubs(all);
    profile.removeWhere((k, _) => nsfwSubs.contains(k));
    if (profile.isEmpty && userInterest.isEmpty) return [];
    // No hard cap: fetch progressively, a few new subs per pass (each cached a day).
    final top = (profile.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(30).map((e) => e.key).toList();
    final want = top;
    _fetchTimer?.cancel(); // settle slider drags before hitting the network
    _fetchTimer = Timer(const Duration(milliseconds: 900), () => _fetchSubs(want, null));
    final tags = [for (final s in top) tag(s)];
    final mixes = <String, Mix>{};

    // author -> sub -> posts, from saved posts and Arctic Shift samples.
    final bySub = <String, Map<String, int>>{};
    final names = <String, String>{};
    void add(String author, String sub, int n) {
      final a = author.toLowerCase();
      if (_skip.contains(a) || exclude.contains(a)) return;
      names[a] ??= author;
      final m = bySub[a] ??= {};
      m[sub] = (m[sub] ?? 0) + n;
    }

    var i = 0;
    for (final p in all) {
      if (++i % 1500 == 0) await Future<void>.delayed(Duration.zero); // keep frames flowing
      add(p.author, p.subreddit.toLowerCase(), 1);
      (mixes[p.author.toLowerCase()] ??= Mix()).addPost(p);
    }
    final d0 = await Db.db;
    final inTags = 'sub IN (${List.filled(tags.length, '?').join(',')})';
    for (final r in tags.isEmpty ? const <Map<String, Object?>>[] : await d0.query('author_mix', where: inTags, whereArgs: tags)) {
      final m = mixes[r['author'] as String] ??= Mix();
      m.n += r['n'] as int;
      m.img += r['img'] as int;
      m.vid += r['vid'] as int;
      m.gal += r['gal'] as int;
      m.txt += r['txt'] as int;
      m.nsfw += r['nsfw'] as int;
      m.subs.add((r['sub'] as String).split('@').first);
      if (m.titles.length < 4000) m.titles.write(' ${r['titles']}');
    }
    final d = await Db.db;
    if (tags.isNotEmpty) {
      final rows = await d.query('sub_authors', where: inTags, whereArgs: tags);
      for (final r in rows) {
        add(r['author'] as String, (r['sub'] as String).split('@').first, r['n'] as int);
      }
    }

    // Same content (crossposts, same file, same picture) as the target accounts.
    final keys = <String>{}, hashes = <int>{};
    for (final p in all) {
      if (!contentOf.contains(p.author.toLowerCase())) continue;
      keys.addAll(Dedupe.exactKeys(p).where((k) => !k.startsWith('id:')));
      for (final m in p.media.take(2)) {
        final h = Dedupe.cachedHash(m.thumb);
        if (h != null && h != 0) hashes.add(h);
      }
    }
    final shared = <String, int>{};
    final sharedWith = <String, String>{};
    if (keys.isNotEmpty || hashes.isNotEmpty) {
      final ownerOf = <String, String>{};
      for (final p in all) {
        if (contentOf.contains(p.author.toLowerCase())) {
          for (final k in Dedupe.exactKeys(p)) {
            ownerOf[k] ??= p.author;
          }
        }
      }
      var j = 0;
      for (final p in all) {
        if (++j % 1000 == 0) await Future<void>.delayed(Duration.zero);
        final a = p.author.toLowerCase();
        if (contentOf.contains(a) || _skip.contains(a) || exclude.contains(a)) continue;
        String? hit;
        for (final k in Dedupe.exactKeys(p)) {
          if (!k.startsWith('id:') && keys.contains(k)) { hit = ownerOf[k]; break; }
        }
        if (hit == null && p.media.take(2).any((m) => hashes.contains(Dedupe.cachedHash(m.thumb)))) hit = '';
        if (hit != null) {
          shared[a] = (shared[a] ?? 0) + 1;
          if (hit.isNotEmpty) sharedWith[a] ??= hit;
          names[a] ??= p.author;
        }
      }
    }

    final out = <Suggestion>[];
    for (final a in {...bySub.keys, ...shared.keys}) {
      final subs = bySub[a] ?? const {};
      var s = 0.0;
      final hits = <(String, double)>[];
      subs.forEach((sub, n) {
        final w = profile[sub];
        if (w == null) return;
        final v = w * (1 + log(n));
        s += v;
        hits.add((sub, v));
      });
      final sh = shared[a] ?? 0;
      s += sh * 6 + (userInterest[a] ?? 0) * 2;
      if (s <= 0 || (hits.isEmpty && sh == 0 && (userInterest[a] ?? 0) < 1)) continue;
      // Light penalty for one-post drive-bys so steady posters rank higher.
      final total = subs.values.fold<int>(0, (x, y) => x + y);
      if (total < 2 && sh == 0) s *= 0.5;
      hits.sort((x, y) => y.$2.compareTo(x.$2));
      var nsfwN = 0;
      subs.forEach((sub, n) => nsfwSubs.contains(sub) ? nsfwN += n : null);
      final mix = mixes[a] ?? Mix();
      out.add(Suggestion(names[a]!, s, _reason(hits.map((h) => h.$1).take(2).toList(), sh, sharedWith[a], likeUser),
          nsfwHint: nsfwN * 2 > total || (mix.n > 0 && mix.nsfw * 2 > mix.n), mix: mix));
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return out.take(150).toList();
  }

  /// Subs where most posts are marked over_18, from saved posts and Arctic Shift samples.
  static Future<Set<String>> _nsfwSubs(List<Post> all) async {
    final n = <String, (int, int)>{};
    for (final p in all) {
      final s = p.subreddit.toLowerCase();
      final c = n[s] ?? (0, 0);
      n[s] = (c.$1 + (p.raw['over_18'] == true ? 1 : 0), c.$2 + 1);
    }
    final out = {for (final e in n.entries) if (e.value.$2 >= 3 && e.value.$1 * 2 > e.value.$2) e.key};
    final d = await Db.db;
    for (final r in await d.query('sub_meta')) {
      if ((r['nsfw'] as num) > 0.5) out.add(r['sub'] as String);
    }
    return out;
  }

  static String _reason(List<String> subs, int shared, String? with_, Map<String, Map<String, int>> likeUser) {
    if (shared > 0) {
      return with_ != null ? 'posts the same pics as u/$with_' : 'posts the same pics you looked at';
    }
    if (subs.isEmpty) return 'you open their posts a lot';
    final like = <String, int>{};
    for (final s in subs) {
      likeUser[s]?.forEach((u, n) => like[u] = (like[u] ?? 0) + n);
    }
    final where = subs.map((s) => 'r/$s').join(' and ');
    if (like.isEmpty) return 'posts in $where, which you like';
    final u = (like.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    return 'posts in $where like u/$u';
  }

  /// Samples recent authors of a few subs from Arctic Shift, one at a time, at most once a day each.
  static Future<void> _fetchSubs(List<String> subs, DateTimeRange? win) async {
    if (_fetching || DateTime.now().isBefore(_cooldown) || subs.isEmpty) return;
    _fetching = true;
    var got = false;
    try {
      final d = await Db.db;
      final dayAgo = DateTime.now().millisecondsSinceEpoch - 86400000;
      var fetched = 0;
      for (final real in subs) {
        if (fetched >= 6) break; // a few per pass; the next pass picks up the rest
        final s = win == null ? real : '$real@${win.start.millisecondsSinceEpoch ~/ 86400000}-${win.end.millisecondsSinceEpoch ~/ 86400000}';
        final r = await d.query('sub_authors', columns: ['fetched'], where: 'sub=?', whereArgs: [s], limit: 1);
        if (r.isNotEmpty && (r.first['fetched'] as int) > dayAgo) continue;
        fetched++;
        final rows = await Archive.subredditPosts(real, after: win?.start, before: win?.end);
        final n = <String, int>{};
        if (rows.isNotEmpty) {
          await d.insert('sub_meta', {'sub': real, 'nsfw': rows.where((p) => p['over_18'] == true).length / rows.length, 'fetched': DateTime.now().millisecondsSinceEpoch},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        final mx = <String, Mix>{};
        for (final row in rows) {
          final a = '${row['author'] ?? ''}';
          if (a.isEmpty || a == '[deleted]') continue;
          if (row['over_18'] == true) {
            (mx[a.toLowerCase()] ??= Mix()).addHidden();
            continue;
          }
          final post = Post.fromJson(row);
          if (post != null) (mx[a.toLowerCase()] ??= Mix()).addPost(post);
        }
        final mb = d.batch();
        mb.delete('author_mix', where: 'sub=?', whereArgs: [s]);
        mx.forEach((a, m) => mb.insert('author_mix', {'author': a, 'sub': s, 'n': m.n, 'img': m.img, 'vid': m.vid, 'gal': m.gal, 'txt': m.txt, 'nsfw': m.nsfw, 'titles': m.titles.toString(), 'fetched': DateTime.now().millisecondsSinceEpoch}));
        await mb.commit(noResult: true);
        for (final p in rows) {
          final a = '${p['author'] ?? ''}';
          if (a.isNotEmpty && a != '[deleted]') n[a] = (n[a] ?? 0) + 1;
        }
        final b = d.batch();
        b.delete('sub_authors', where: 'sub=?', whereArgs: [s]);
        final now = DateTime.now().millisecondsSinceEpoch;
        if (n.isEmpty) b.insert('sub_authors', {'sub': s, 'author': '[deleted]', 'n': 0, 'fetched': now});
        n.forEach((a, c) => b.insert('sub_authors', {'sub': s, 'author': a, 'n': c, 'fetched': now}, conflictAlgorithm: ConflictAlgorithm.replace));
        await b.commit(noResult: true);
        got = true;
      }
    } catch (_) {
      _cooldown = DateTime.now().add(const Duration(minutes: 10)); // back off on errors or rate limits
    } finally {
      _fetching = false;
    }
    if (got) {
      clearCache();
      bump();
    }
  }
}


/// Recent media posts per suggested account: fetched ONCE (2 at a time), cached, and reused by the
/// card strip, the full preview and the inline expand. Falls back to locally saved posts.
class AccountPreview {
  static final Map<String, List<Post>> _m = {};
  static final Map<String, Future<List<Post>>> _f = {};
  static int _running = 0;
  static final List<Completer<void>> _wait = [];

  static List<Post>? peek(String user) => _m[user.toLowerCase()];

  static Future<List<Post>> get(String user) {
    final k = user.toLowerCase();
    final c = _m[k];
    if (c != null) return Future.value(c);
    return _f[k] ??= _fetch(user).then((r) {
      _m[k] = r;
      return r;
    }).whenComplete(() => _f.remove(k));
  }

  static Future<List<Post>> _fetch(String user) async {
    if (_running >= 2) {
      final w = Completer<void>();
      _wait.add(w);
      await w.future;
    }
    _running++;
    try {
      final rows = await Archive.userPosts(user);
      final out = <Post>[];
      for (final r in rows) {
        final p = Post.fromJson(r);
        if (p != null && p.media.isNotEmpty) out.add(p);
      }
      if (out.isNotEmpty) return out;
    } catch (_) {
      // fall through to local posts
    } finally {
      _running--;
      if (_wait.isNotEmpty) _wait.removeAt(0).complete();
    }
    final k = user.toLowerCase();
    final all = await Suggest.everything();
    return all.where((p) => p.author.toLowerCase() == k && p.media.isNotEmpty).take(60).toList();
  }
}
