import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'auth.dart';
import 'db.dart';
import 'models.dart';
import 'public_sources.dart';

const appVersion = '1.3.8';
const _ua = 'android:com.alok.hobee:v$appVersion (personal gallery app)';

/// Archive providers. Order + enabled state are user-configurable in Settings.
enum ArchiveProvider { pullpush, arcticShift }

const archiveLabels = {ArchiveProvider.pullpush: 'PullPush', ArchiveProvider.arcticShift: 'Arctic Shift'};

class ArchiveConfig {
  static final order = ValueNotifier<List<ArchiveProvider>>([ArchiveProvider.pullpush, ArchiveProvider.arcticShift]);
  // PullPush now 429s all free API traffic, so it is off by default (still toggleable).
  static final enabled = ValueNotifier<Set<ArchiveProvider>>({ArchiveProvider.arcticShift});
  /// Optional paid PullPush key; sent as a header only when set.
  static final pullpushKey = ValueNotifier<String>('');

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final o = sp.getStringList('archOrder');
    if (o != null) {
      final l = o.map((n) => ArchiveProvider.values.where((p) => p.name == n)).expand((x) => x).toList();
      for (final p in ArchiveProvider.values) {
        if (!l.contains(p)) l.add(p);
      }
      order.value = l;
    }
    final e = sp.getStringList('archEnabled');
    if (e != null) enabled.value = ArchiveProvider.values.where((p) => e.contains(p.name)).toSet();
    // One-time migration (1.3.2): switch PullPush off for existing installs.
    if (sp.getBool('ppOff132') != true) {
      enabled.value = {...enabled.value}..remove(ArchiveProvider.pullpush);
      if (enabled.value.isEmpty) enabled.value = {ArchiveProvider.arcticShift};
      await sp.setBool('ppOff132', true);
      await sp.setStringList('archEnabled', enabled.value.map((p) => p.name).toList());
    }
    pullpushKey.value = sp.getString('pullpushKey') ?? '';
  }

  static Future<void> setPullpushKey(String k) async {
    pullpushKey.value = k.trim();
    final sp = await SharedPreferences.getInstance();
    await sp.setString('pullpushKey', pullpushKey.value);
  }

  static Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('archOrder', order.value.map((p) => p.name).toList());
    await sp.setStringList('archEnabled', enabled.value.map((p) => p.name).toList());
  }
}

/// Short user-visible note, e.g. 'PullPush unavailable, using Arctic Shift'.
final archiveNote = ValueNotifier<String?>(null);

/// Per-provider result of the last archive page, for precise status text.
class ProviderStatus {
  final ArchiveProvider? provider; // null = Reddit public listing
  final int? count; // posts returned (null on error)
  final String? error; // short reason, e.g. 'blocked (rate-limited)'
  final String? detail; // raw error for the expandable detail
  final String? name; // label override for no-login sources (RSS, Redlib)
  const ProviderStatus(this.provider, {this.count, this.error, this.detail, this.name});
  bool get ok => error == null;
  String get label => name ?? (provider == null ? 'Reddit public' : archiveLabels[provider]!);
}

final archiveStatus = ValueNotifier<List<ProviderStatus>>([]);

class ArchiveError implements Exception {
  final String message;
  ArchiveError(this.message);
  @override
  String toString() => message;
}

class _Unavailable implements Exception {
  final String why, detail;
  _Unavailable(this.why, [String? detail]) : detail = detail ?? why;
  @override
  String toString() => why;
}

String _bodySnippet(String b) {
  final t = b.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 300 ? '${t.substring(0, 300)}…' : t;
}

/// Source key: "deep:NAME" or "deep:NAME@SUB".
bool isDeep(String source) => source.startsWith('deep:');
(String, String?) deepParts(String source) {
  final s = source.substring(5);
  final i = s.indexOf('@');
  return i < 0 ? (s, null) : (s.substring(0, i), s.substring(i + 1));
}

bool isLive(Post p) => p.raw['_hobee_live'] == true;
bool isRemoved(Post p) {
  final r = p.raw;
  return r['removed_by_category'] != null || r['author'] == '[deleted]' || r['selftext'] == '[removed]' || r['selftext'] == '[deleted]';
}

class Archive {
  static final Map<String, DateTime> _last = {};

  /// ~1 request/second per host.
  static Future<void> _pace(String host) async {
    final l = _last[host];
    if (l != null) {
      final wait = const Duration(milliseconds: 1100) - DateTime.now().difference(l);
      if (!wait.isNegative) await Future.delayed(wait);
    }
    _last[host] = DateTime.now();
  }

  static Future<List<Map<String, dynamic>>> _getJsonList(Uri u, {bool retry429 = false, Map<String, String> extra = const {}}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      await _pace(u.host);
      final http.Response r;
      try {
        r = await http.get(u, headers: {'User-Agent': _ua, 'Accept': 'application/json', ...extra}).timeout(const Duration(seconds: 45));
      } on TimeoutException {
        throw _Unavailable('timed out', 'No response in 45 s from ${u.host}');
      } catch (e) {
        throw _Unavailable('network error', '$e');
      }
      final ct = r.headers['content-type'] ?? '';
      if (r.statusCode == 429 && retry429 && attempt == 0) {
        // Respect the server's reset hint (seconds); cap the wait.
        final reset = int.tryParse(r.headers['x-ratelimit-reset'] ?? '') ?? 5;
        await Future.delayed(Duration(seconds: reset.clamp(1, 60)));
        continue;
      }
      final detail = 'HTTP ${r.statusCode} from $u\n${_bodySnippet(r.body)}';
      if (r.statusCode == 429) throw _Unavailable('blocked (rate-limited)', detail);
      if (r.statusCode == 403) throw _Unavailable('blocked (HTTP 403)', detail);
      if (r.statusCode >= 500) throw _Unavailable('server error (HTTP ${r.statusCode})', detail);
      if (r.statusCode != 200) throw _Unavailable('HTTP ${r.statusCode}', detail);
      if (ct.contains('html') || r.body.trimLeft().startsWith('<')) throw _Unavailable('blocked (HTML page instead of JSON)', detail);
      final Object? j;
      try {
        j = jsonDecode(r.body);
      } on FormatException catch (e) {
        throw _Unavailable('bad JSON', '$e\n$detail');
      }
      if (j is! Map) throw _Unavailable('unexpected response', detail);
      final data = j['data'];
      // A valid empty result ("data": [] or null with no error) is NOT an outage.
      if (data == null && j['error'] == null) return [];
      if (data is! List) throw _Unavailable(j['error'] != null ? '${j['error']}' : 'unexpected response', detail);
      return data.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    }
    throw _Unavailable('blocked (rate-limited)', 'HTTP 429 twice from ${u.host}');
  }

  /// Author query, plus (Arctic Shift, no sub filter) the user's own profile subreddit `u_NAME`:
  /// profile posts whose author was later set to [deleted] are only reachable that way.
  static const _pageSize = 100;

  /// Author query, plus (Arctic Shift, no sub filter) the user's own profile subreddit `u_NAME`:
  /// profile posts whose author was later set to [deleted] are only reachable that way.
  /// Returns the merged rows and this provider's next `before` cursor (epoch seconds): the newest
  /// "oldest timestamp" among sub-queries that returned a FULL page. Using the overall oldest row
  /// would skip a gap when one sub-query reaches much further back than the other. null = exhausted.
  static Future<(List<Map<String, dynamic>>, int?)> _queryAll(ArchiveProvider p, String name, String? sub, int? before) async {
    final rows = await _query(p, name, sub, before);
    int? next = _cursorOf(rows);
    if (p == ArchiveProvider.arcticShift && sub == null) {
      try {
        final prof = await _query(p, '', 'u_$name', before);
        final ids = rows.map((r) => r['id']).toSet();
        rows.addAll(prof.where((r) => !ids.contains(r['id'])));
        final pn = _cursorOf(prof);
        if (pn != null && (next == null || pn > next)) next = pn;
      } on _Unavailable {
        // profile query is a bonus; author results still count
      }
    }
    return (rows, next);
  }

  /// Oldest timestamp of a full page (more may exist before it); null when the page was short (end).
  static int? _cursorOf(List<Map<String, dynamic>> rows) {
    if (rows.length < _pageSize) return null;
    final t = rows.map(_ts).where((t) => t > 0).fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    return t;
  }

  static Future<List<Map<String, dynamic>>> _query(ArchiveProvider p, String name, String? sub, int? before) {
    switch (p) {
      case ArchiveProvider.pullpush:
        return _getJsonList(Uri.https('api.pullpush.io', '/reddit/search/submission/', {
          'author': name, 'size': '100', 'sort': 'desc', 'sort_type': 'created_utc',
          'subreddit': ?sub,
          if (before != null) 'before': '$before',
        }), extra: ArchiveConfig.pullpushKey.value.isEmpty ? const {} : {'Authorization': 'Bearer ${ArchiveConfig.pullpushKey.value}', 'X-API-Key': ArchiveConfig.pullpushKey.value});
      case ArchiveProvider.arcticShift:
        return _getJsonList(Uri.https('arctic-shift.photon-reddit.com', '/api/posts/search', {
          if (name.isNotEmpty) 'author': name, 'limit': '100', 'sort': 'desc',
          'subreddit': ?sub,
          if (before != null) 'before': '$before',
        }), retry429: true);
    }
  }

  /// Settings 'Test archives': one small request per provider; returns a human-readable line each.
  static Future<List<String>> test({String author = 'spez'}) async {
    final out = <String>[];
    for (final p in ArchiveProvider.values) {
      final sw = Stopwatch()..start();
      try {
        final rows = await _query(p, author, null, null);
        out.add('${archiveLabels[p]}: OK (HTTP 200, ${rows.length} posts for u/$author, ${sw.elapsedMilliseconds} ms)');
      } on _Unavailable catch (e) {
        out.add('${archiveLabels[p]}: ${e.why}\n${e.detail}');
      } catch (e) {
        out.add('${archiveLabels[p]}: $e');
      }
    }
    return out;
  }

  static int _ts(Map d) => ((d['created_utc'] ?? 0) is num) ? (d['created_utc'] as num).toInt() : int.tryParse('${d['created_utc']}') ?? 0;

  /// One page from every enabled/available archive + one live Reddit page. Returns new posts, -1 when done.
  static Future<int> fetchMore(String source, {bool fromStart = false}) async {
    final (name, sub) = deepParts(source);
    final (mainCur, done) = await Db.cursor(source);
    if (done && !fromStart) return -1;
    // Archive `before` cursor lives under its own key so the live Reddit cursor can keep paging
    // after the archives run out (and vice versa). Older installs stored it under [source].
    final archKey = 'arch|$source';
    var (archCur, archDone) = await Db.cursor(archKey);
    if (archCur == null && !archDone) {
      final (legacy, _) = await Db.cursor(source);
      if (int.tryParse(legacy ?? '') != null) archCur = legacy;
    }
    // Refresh (fromStart) re-reads the newest page but keeps the saved paging position.
    final keepPos = fromStart && (archCur != null || archDone);
    final before = fromStart ? null : int.tryParse(archCur ?? '');
    final providers = archDone && !fromStart ? <ArchiveProvider>[] : ArchiveConfig.order.value.where(ArchiveConfig.enabled.value.contains).toList();
    final byId = <String, Map<String, dynamic>>{};
    final nextPer = <int>[];
    final statuses = <ProviderStatus>[];
    for (final p in providers) {
      try {
        var (rows, pNext) = await _queryAll(p, name, sub, before);
        // Fallback: try the lower-cased author if an exact-case lookup returned nothing.
        if (rows.isEmpty && before == null && name != name.toLowerCase()) (rows, pNext) = await _queryAll(p, name.toLowerCase(), sub, before);
        // Exact (case-insensitive) author match; drops any fuzzy/partial matches.
        rows = rows.where((r) => '${r['author'] ?? ''}'.toLowerCase() == name.toLowerCase() || r['author'] == '[deleted]' ||
            '${r['subreddit'] ?? ''}'.toLowerCase() == 'u_${name.toLowerCase()}').toList();
        for (final r in rows) {
          final id = '${r['id'] ?? ''}';
          if (id.isEmpty) continue;
          byId.putIfAbsent(id, () => r..['_hobee_src'] = p.name);
        }
        if (pNext != null) nextPer.add(pNext);
        statuses.add(ProviderStatus(p, count: rows.length));
      } on _Unavailable catch (e) {
        statuses.add(ProviderStatus(p, error: e.why, detail: e.detail));
      } catch (e) {
        statuses.add(ProviderStatus(p, error: 'error', detail: '$e'));
      }
    }
    final bad0 = statuses.where((s) => !s.ok).length;
    // Live Reddit (OAuth when logged in, else the public JSON listing): marks posts still present
    // and covers very recent posts the archives haven't ingested yet.
    final (liveIds, liveStatuses, liveDone) = await _livePage(source, name, sub, fromStart);
    statuses.addAll(liveStatuses);
    archiveStatus.value = statuses;
    final bad = statuses.where((s) => !s.ok).toList();
    archiveNote.value = bad.isEmpty ? null : bad.map((s) => '${s.label}: ${s.error}').join(' · ');
    if (providers.isNotEmpty && bad0 == providers.length && liveIds.isEmpty) {
      throw ArchiveError('No archive reachable: ${archiveNote.value}');
    }

    final known = await Db.liveIds(source);
    final posts = <Post>[];
    for (final r in byId.values) {
      r['_hobee_live'] = known.contains(r['id']) || liveIds.contains(r['id']);
      final p = Post.fromJson(r);
      if (p != null) posts.add(p);
    }
    // Full archive JSON may replace thin RSS/Redlib copies (keeps the live flag set above).
    final thin = await Db.thinIds(source);
    await Db.savePosts(source, posts.where((p) => !known.contains(p.id) || thin.contains(p.id)).toList());
    // Archive cursor advances when at least one provider answered (a rate-limited PullPush must not
    // freeze paging on the same page). If every provider failed, the old cursor is kept for a retry
    // and the search is NOT marked finished.
    final archOk = statuses.where((s) => s.provider != null && s.ok).isNotEmpty;
    if (keepPos) {
      // leave archive cursor as saved
    } else if (providers.isNotEmpty && archOk) {
      // Newest of each provider's full-page oldest, so no provider skips a gap (dupes merge by id).
      final next = nextPer.isEmpty ? null : nextPer.reduce((a, b) => a > b ? a : b);
      if (next != null && before != null && next >= before) {
        // Safety: a cursor that doesn't move would return the same page forever.
        await Db.setCursor(archKey, '${before - 1}');
      } else {
        await Db.setCursor(archKey, next == null ? null : '$next');
      }
      archDone = next == null;
    } else if (providers.isEmpty) {
      archDone = true;
    }
    // Whole deep source is finished only when the archives AND the live listing are exhausted.
    if (!fromStart || mainCur == null) await Db.setCursor(source, archDone && liveDone ? null : 'more');
    return posts.length;
  }

  /// Live page. Logged in: oauth.reddit.com (most reliable). Logged out, in order with fallback:
  /// Reddit public JSON -> Reddit RSS -> Redlib instance (auto-fallback across instances).
  /// All share one t3_ "after" cursor so paging continues whichever source answers.
  /// Third value: true when the live listing has no further pages (or no live source answered).
  static Future<(Set<String>, List<ProviderStatus>, bool)> _livePage(String source, String name, String? sub, bool fromStart) async {
    final key = 'live|$source';
    final (after, done) = await Db.cursor(key);
    if (done && !fromStart) return (<String>{}, <ProviderStatus>[], true);
    final pageAfter = (!fromStart && after != null) ? after : null;
    final logged = Auth.i.loggedIn;
    final statuses = <ProviderStatus>[];
    List<Map<String, dynamic>>? rows;
    String? next;
    String srcTag = 'reddit';
    if (logged) {
      try {
        final j = await Api.get('/user/$name/submitted', {'limit': '100', 'sort': 'new', 'after': ?pageAfter});
        rows = [for (final c in (j['data']['children'] as List)) if (c['kind'] == 't3') Map<String, dynamic>.from(c['data'])];
        next = j['data']['after'] as String?;
      } catch (_) {}
    } else {
      // 1) Reddit public JSON
      try {
        final j = await _publicListing(name, pageAfter);
        rows = [for (final c in (j['data']['children'] as List)) if (c['kind'] == 't3') Map<String, dynamic>.from(c['data'])];
        next = j['data']['after'] as String?;
        srcTag = 'redditPublic';
        statuses.add(ProviderStatus(null, name: 'Reddit JSON', count: rows.length));
      } on _Unavailable catch (e) {
        statuses.add(ProviderStatus(null, name: 'Reddit JSON', error: e.why, detail: e.detail));
      } catch (e) {
        statuses.add(ProviderStatus(null, name: 'Reddit JSON', error: 'error', detail: '$e'));
      }
      // 2) Reddit RSS
      if (rows == null && RedlibConfig.rssEnabled.value) {
        try {
          await _pace('www.reddit.com');
          final pg = await RedditRss.page(name, pageAfter, _ua);
          rows = pg.rows;
          next = pg.after;
          srcTag = 'rss';
          statuses.add(ProviderStatus(null, name: 'Reddit RSS', count: rows.length));
        } on PublicFail catch (e) {
          statuses.add(ProviderStatus(null, name: 'Reddit RSS', error: e.why, detail: e.detail));
        } catch (e) {
          statuses.add(ProviderStatus(null, name: 'Reddit RSS', error: 'error', detail: '$e'));
        }
      }
      // 3) Redlib
      if (rows == null && RedlibConfig.enabled.value) {
        try {
          final pg = await Redlib.page(name, pageAfter, _ua);
          rows = pg.rows;
          next = pg.after;
          srcTag = 'redlib';
          statuses.add(ProviderStatus(null, name: 'Redlib (${pg.via})', count: rows.length));
        } on PublicFail catch (e) {
          statuses.add(ProviderStatus(null, name: 'Redlib', error: e.why, detail: e.detail));
        } catch (e) {
          statuses.add(ProviderStatus(null, name: 'Redlib', error: 'error', detail: '$e'));
        }
      }
    }
    if (rows == null) return (<String>{}, statuses, true);
    final live = <Post>[];
    for (final d in rows) {
      if (sub != null && '${d['subreddit']}'.toLowerCase() != sub.toLowerCase()) continue;
      d['_hobee_live'] = true;
      d['_hobee_src'] = srcTag;
      if (srcTag == 'rss' || srcTag == 'redlib') d['_hobee_thin'] = true;
      final p = Post.fromJson(d);
      if (p != null) live.add(p);
    }
    // Full Reddit JSON replaces archive copies; RSS/Redlib rows are thinner, so only add ids we don't have.
    if (srcTag == 'reddit' || srcTag == 'redditPublic') {
      await Db.savePosts(source, live);
    } else {
      final known = await Db.liveIds(source);
      await Db.savePosts(source, live.where((p) => !known.contains(p.id)).toList());
    }
    if (!fromStart || after == null) await Db.setCursor(key, next);
    return (live.map((p) => p.id).toSet(), statuses, fromStart && after != null ? false : next == null);
  }

  /// Public, logged-out read of reddit.com/user/NAME/submitted.json. If Reddit answers 403/429/HTML
  /// the source is simply reported unavailable; no workaround is attempted.
  static Future<Map> _publicListing(String name, String? after) async {
    final u = Uri.https('www.reddit.com', '/user/$name/submitted.json', {'limit': '100', 'raw_json': '1', 'sort': 'new', 'after': ?after});
    await _pace(u.host);
    final http.Response r;
    try {
      r = await http.get(u, headers: {'User-Agent': _ua, 'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw _Unavailable('timed out', 'No response in 20 s from ${u.host}');
    } catch (e) {
      throw _Unavailable('network error', '$e');
    }
    final detail = 'HTTP ${r.statusCode} from $u\n${_bodySnippet(r.body)}';
    if (r.statusCode != 200) throw _Unavailable('unavailable (HTTP ${r.statusCode})', detail);
    if ((r.headers['content-type'] ?? '').contains('html') || r.body.trimLeft().startsWith('<')) {
      throw _Unavailable('unavailable (HTML page)', detail);
    }
    final j = jsonDecode(r.body);
    if (j is! Map || j['data'] is! Map) throw _Unavailable('unexpected response', detail);
    return j;
  }
}

/// Media availability: original URL → preview.redd.it → Wayback. Cached in SQLite.
/// Media is only reported gone on positive evidence (404/410, a known 'removed' redirect); 403/429/5xx/network errors
/// are "unsure" and the media keeps showing.
class MediaCheck {
  static final Map<String, _Job> _inflight = {};
  /// A single check never holds a slot longer than this (a slow Wayback or a stalled socket used to).
  static Duration checkTimeout = const Duration(seconds: 25);
  // Seams for tests.
  @visibleForTesting
  static http.Client Function() client = http.Client.new;
  @visibleForTesting
  static Future<String?> Function(String key) readCache = Db.mediaStatus;
  @visibleForTesting
  static Future<void> Function(String key, String result) writeCache = Db.setMediaStatus;
  @visibleForTesting
  static Future<String?> Function(String url) wayback = _wayback;
  @visibleForTesting
  static int retries = 1;
  @visibleForTesting
  static void reset() { _inflight.clear(); gone.value = const {}; _active = 0; _waiters.clear(); }

  /// Post ids whose first image turned out to be gone everywhere (used by 'Hide gone images').
  static final gone = ValueNotifier<Set<String>>(const {});
  static void markGone(String id) {
    if (!gone.value.contains(id)) gone.value = {...gone.value, id};
  }

  // Bounded concurrency so a fast scroll doesn't fire hundreds of probes at once. Waiters are served newest first
  // (what you're looking at now) and waiters nobody wants anymore (tile scrolled away and disposed) are dropped.
  static const maxConcurrent = 6;
  static int _active = 0;
  static final List<_Waiter> _waiters = [];
  @visibleForTesting
  static int get activeSlots => _active;
  @visibleForTesting
  static int get queued => _waiters.length;

  static Future<T> _limit<T>(Future<T> Function() f, bool Function() wanted) async {
    if (_active >= maxConcurrent) {
      final w = _Waiter(wanted);
      _waiters.add(w);
      if (!await w.c.future) throw const SkippedCheck();
    } else {
      _active++;
    }
    try {
      return await f();
    } finally {
      _active--;
      _next();
    }
  }

  static void _next() {
    while (_active < maxConcurrent && _waiters.isNotEmpty) {
      final w = _waiters.removeLast();
      if (w.wanted()) {
        _active++; // hand the slot over before anyone else can grab it
        w.c.complete(true);
      } else {
        w.c.complete(false);
      }
    }
  }

  /// Forget a result so a tap on 'retry' really checks again.
  static Future<void> forget(Post post, MediaItem item, {bool thumb = false}) async {
    final k = _keyOf(post, item, thumb);
    _inflight.remove('$thumb|$k');
    await writeCache(_cacheKey(k), '?');
    gone.value = {...gone.value}..remove(post.id);
  }

  static String _keyOf(Post post, MediaItem item, bool thumb) {
    final key = thumb ? item.thumb : item.full;
    // Never share an empty key between posts (that cached one post's result for all of them).
    return key.isNotEmpty ? key : (item.url.isNotEmpty ? item.url : 'post:${post.id}');
  }

  /// Returns a working URL, or null if the media is gone. [wanted] says whether the caller still cares (a tile
  /// that scrolled off returns false so its queued check is skipped). Timeouts and skips are never cached, so the
  /// next time the tile shows up it simply checks again.
  static Future<String?> resolve(Post post, MediaItem item, {bool thumb = false, bool Function()? wanted}) {
    final k = _keyOf(post, item, thumb);
    final id = '$thumb|$k';
    final job = _inflight[id];
    if (job != null) {
      if (wanted != null) job.wanted.add(wanted);
      return job.future;
    }
    final j = _Job();
    if (wanted != null) j.wanted.add(wanted);
    _inflight[id] = j;
    j.future = _limit(() => _resolve(post, item, k).timeout(checkTimeout), j.isWanted).then((u) {
      if (u == null) markGone(post.id);
      return u;
    }, onError: (Object e) {
      if (_inflight[id] == j) _inflight.remove(id);
      // Skipped (nobody's looking), timeout or unexpected error: not proof of anything. Hand back the raw URL
      // uncached; the next tile that shows this post checks again.
      return k.startsWith('http') ? k : (item.thumb.isNotEmpty ? item.thumb : null);
    });
    return j.future;
  }

  // v3: <=1.3.6 probed with a 1-byte Range request, which preview.redd.it answers with 206 even for deleted
  // images (a full GET is 404 + a grey placeholder), so dead previews were cached as working. Ignore those.
  static String _cacheKey(String k) => 'v3|$k';

  static Future<String?> _resolve(Post post, MediaItem item, String key) async {
    final cached = await readCache(_cacheKey(key));
    if (cached != null && cached != '?') return cached.isEmpty ? null : cached;
    final cands = <String>[
      if (key.startsWith('http')) key,
      if (item.type == MediaType.image) ...[item.full, item.url, ?item.preview],
      ..._previews(post.raw),
      if (item.thumb.isNotEmpty) item.thumb,
    ].where((u) => u.startsWith('http')).toSet();
    String? ok;
    String? unsure; // network/403/429: don't call it gone, don't cache
    final c = client();
    try {
      for (final u in cands) {
        var a = await alive(u, c);
        // Network hiccup / 429 / 5xx: back off and ask once more before moving on.
        for (var t = 0; a == null && t < retries; t++) {
          await Future.delayed(Duration(milliseconds: 600 * (1 << t)));
          a = await alive(u, c);
        }
        if (a == true) { ok = u; break; }
        if (a == null) unsure ??= u;
      }
    } finally {
      c.close();
    }
    if (ok == null && unsure != null) return unsure;
    if (ok == null && cands.isEmpty) return key.startsWith('http') ? key : null;
    // Wayback: try the original upload first, then the preview it was resized from.
    for (final w in {if (item.url.startsWith('http')) item.url, if (key.startsWith('http')) key, ?item.preview}) {
      if (ok != null) break;
      ok = await wayback(w);
    }
    if (ok == null) debugPrint('hobee: media gone for ${post.id} (${cands.length} candidates tried)');
    await writeCache(_cacheKey(key), ok ?? '');
    return ok;
  }

  static List<String> _previews(Map d) {
    final out = <String>[];
    try {
      final img = d['preview']['images'][0];
      out.add(unesc(img['source']['url']));
      for (final r in (img['resolutions'] as List).reversed) {
        out.add(unesc(r['url']));
      }
    } catch (_) {}
    return out.where((u) => u.startsWith('http')).toList();
  }

  /// Pure verdict for one HTTP hop. true = served, false = clearly gone, null = unsure (keep showing).
  @visibleForTesting
  static bool? verdict(Uri url, int code, String? location) {
    if (code == 404 || code == 410) return false;
    if (code >= 300 && code < 400) {
      final loc = location ?? '';
      if (loc.contains('removed.png') || RegExp(r'/removed(\?|$)').hasMatch(loc)) return false;
      // i.imgur.com/<id>.jpg → imgur.com/<id> (HTML page) is imgur's "no such image".
      if (url.host == 'i.imgur.com' && RegExp(r'^https?://(www\.)?imgur\.com/[A-Za-z0-9]+$').hasMatch(loc)) return false;
      return null; // caller follows other redirects
    }
    if (code >= 200 && code < 300) return true; // any served bytes count; no size heuristics
    return null; // 401/403/429/5xx: not proof it's gone
  }

  /// Plain GET whose body is dropped as soon as the status arrives. No Range header: preview.redd.it replies 206 to a
  /// ranged request even when the image is deleted (only the full GET says 404), and HEAD is often 403/405.
  /// Redirects are followed by hand so placeholders like imgur's removed.png are seen.
  @visibleForTesting
  static Future<bool?> alive(String url, [http.Client? c]) async {
    final cl = c ?? client();
    try {
      var u = Uri.parse(url);
      for (var hop = 0; hop < 4; hop++) {
        final rq = http.Request('GET', u)
          ..followRedirects = false
          ..headers.addAll({'User-Agent': _ua, 'Accept': 'image/*,video/*,*/*'});
        final s = await cl.send(rq).timeout(const Duration(seconds: 10));
        unawaited(s.stream.listen(null, cancelOnError: true).cancel().catchError((_) {}));
        final loc = s.headers['location'];
        final v = verdict(u, s.statusCode, loc);
        if (s.statusCode >= 300 && s.statusCode < 400 && v == null && loc != null) {
          u = u.resolve(loc);
          continue;
        }
        return v;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      if (c == null) cl.close();
    }
  }

  static Future<String?> _wayback(String url) async {
    if (url.isEmpty) return null;
    try {
      final r = await http.get(Uri.https('archive.org', '/wayback/available', {'url': url}), headers: {'User-Agent': _ua})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final s = jsonDecode(r.body)['archived_snapshots']?['closest'];
      if (s == null || s['available'] != true) return null;
      // id_ suffix returns the raw archived bytes instead of the Wayback frame.
      final m = RegExp(r'^https?://web\.archive\.org/web/(\d+)/(.*)$').firstMatch('${s['url']}');
      return m == null ? '${s['url']}' : 'https://web.archive.org/web/${m.group(1)}id_/${m.group(2)}';
    } catch (_) {
      return null;
    }
  }
}

class SkippedCheck implements Exception {
  const SkippedCheck();
}

class _Waiter {
  final bool Function() wanted;
  final c = Completer<bool>();
  _Waiter(this.wanted);
}

class _Job {
  late Future<String?> future;
  final List<bool Function()> wanted = [];
  // Checks started without a [wanted] callback (tests, viewer) are always wanted.
  bool isWanted() => wanted.isEmpty || wanted.any((w) => w());
}
