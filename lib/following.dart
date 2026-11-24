import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'archive.dart';
import 'db.dart';
import 'follows.dart';
import 'models.dart';

/// Following feed (no login): every subreddit and user of a profile, merged by date.
///
/// Source key `fol:<profileId>`. Reddit's own no-login endpoints answer 403/429 and Redlib instances either
/// show a bot check or filter NSFW posts, so posts come from Arctic Shift, one paced request per subreddit or
/// user. Each call does a small batch (so the grid fills in as it goes):
///  1. refresh round: newest posts of every entry not checked in the last [freshFor], stalest first,
///     asking only for posts newer than the newest one already seen;
///  2. fill-back: entries whose loaded posts don't yet reach back [subWindow] (subreddits) or [userWindow]
///     (users) go further back, newest gap first, at most [fillPages] pages per entry each round;
///  3. then, when you scroll to the end, paging back one page further per entry.
bool isFollowing(String source) => source.startsWith('fol:');
String followingKey(int profile) => 'fol:$profile';
int? followingProfile(String source) => isFollowing(source) ? int.tryParse(source.substring(4)) : null;

/// Progress line for the status bar, e.g. "Checked 40 of 325 · ~9 min left".
final followingStatus = ValueNotifier<String?>(null);

/// Following feed chips: 0 all, 1 posts in followed subreddits, 2 posts by followed users.
final followingKind = ValueNotifier<int>(0);

class FollowState {
  int at; // last refresh, ms since epoch (0 = never)
  int? newest, oldest; // created_utc range loaded so far
  bool done; // no older posts left
  FollowState({this.at = 0, this.newest, this.oldest, this.done = false});

  factory FollowState.decode(String? s) {
    if (s == null) return FollowState();
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return FollowState(at: m['at'] as int? ?? 0, newest: m['new'] as int?, oldest: m['old'] as int?, done: m['done'] == true);
    } catch (_) {
      return FollowState();
    }
  }
  String encode() => jsonEncode({'at': at, 'new': ?newest, 'old': ?oldest, 'done': done});
}

class Following {
  /// Requests per fetchMore call.
  static int budget = 4; // keeps one call well under the grid's 2-minute timeout, even with a cooldown
  static const freshFor = Duration(minutes: 30);
  static int pageSize = 100; // Arctic Shift maximum; fewer rows back means the entry has no older posts
  /// Refreshing an entry that already has posts only asks for this many newer ones (cheaper for the archive).
  static int refreshSize = 25;
  /// How far back a refresh round preloads on its own; older posts load when you scroll.
  static Duration subWindow = const Duration(days: 60);
  static Duration userWindow = const Duration(days: 180);
  /// Fill-back pages per entry per round, so a very busy subreddit can't hold up the rest for hours.
  static int fillPages = 10;
  /// Arctic Shift answers "slow down" (HTTP 422) at about one request a second, so the feed adapts: it starts
  /// at [minGap] between its requests, doubles the gap (up to [maxGap]) after every slow-down and eases back
  /// towards [minGap] after each success. It runs at whatever pace the archive allows from this network.
  static Duration minGap = const Duration(seconds: 3);
  static Duration maxGap = const Duration(seconds: 15);
  static Duration gap = const Duration(seconds: 3);
  static DateTime? _last;

  /// Next gap after a request: doubled after a slow-down, 20 % shorter after a success, within the limits.
  static Duration nextGap(Duration g, {required bool busy}) {
    final ms = busy ? g.inMilliseconds * 2 : (g.inMilliseconds * 0.8).round();
    return Duration(milliseconds: ms.clamp(minGap.inMilliseconds, maxGap.inMilliseconds));
  }

  /// Bumps when posts were saved (the grid reloads from the database).
  static final version = ValueNotifier<int>(0);

  // One fetch at a time: the refresher, the grid and the background task share the archive's rate limit.
  static Future<void> _lock = Future<void>.value();
  static Future<T> _locked<T>(Future<T> Function() f) {
    final prev = _lock;
    final done = Completer<void>();
    _lock = done.future;
    return prev.then((_) => f()).whenComplete(done.complete);
  }

  // Subreddits / users of each profile, lower-case, for the Following chips.
  static final _sets = <int, (Set<String>, Set<String>)>{};

  static Future<void> loadSets(int pid) async {
    final fs = await FollowStore.follows(pid);
    _sets[pid] = (
      {for (final f in fs) if (f.kind == FollowKind.sub) f.name.toLowerCase()},
      {for (final f in fs) if (f.kind == FollowKind.user) f.name.toLowerCase()},
    );
  }

  /// Applies the Following chips: posts made in a followed subreddit, or by a followed user.
  static List<Post> applyKind(List<Post> posts, String source) {
    final k = followingKind.value;
    final sets = _sets[followingProfile(source) ?? -1];
    if (k == 0 || sets == null) return posts;
    final (subs, users) = sets;
    return k == 1
        ? posts.where((p) => subs.contains(p.subreddit.toLowerCase())).toList()
        : posts.where((p) => users.contains(p.author.toLowerCase())).toList();
  }

  /// One page of an entry from Arctic Shift. Test seam.
  static Future<List<Map<String, dynamic>>> Function(Follow f, {int? after, int? before, int limit}) fetchPage = _arctic;

  static Future<List<Map<String, dynamic>>> _arctic(Follow f, {int? after, int? before, int limit = 100}) => Archive.recentPosts(
      sub: f.kind == FollowKind.sub ? f.name : null, author: f.kind == FollowKind.user ? f.name : null, after: after, before: before, limit: limit);

  static Future<List<Map<String, dynamic>>> _paced(Follow f, {int? after, int? before, required int limit}) async {
    final l = _last;
    if (l != null) {
      final wait = gap - DateTime.now().difference(l);
      if (!wait.isNegative) await Future.delayed(wait);
    }
    try {
      final r = await fetchPage(f, after: after, before: before, limit: limit);
      gap = nextGap(gap, busy: false);
      return r;
    } catch (e) {
      if (_busy(e)) gap = nextGap(gap, busy: true);
      rethrow;
    } finally {
      _last = DateTime.now();
    }
  }

  static bool _busy(Object e) => RegExp(r'slow down|busy|rate|429|timed out|timeout', caseSensitive: false).hasMatch('$e');
  static final _retried = <String, Set<String>>{}; // source -> entries already retried this round

  static final _round = <String, List<Follow>>{}; // source -> entries still to refresh this round
  static final _checked = <String, (int, int, int)>{}; // source -> (checked, total, failed) this round
  static final _filled = <String, Map<String, int>>{}; // source -> fill-back pages used per entry this round
  static final _filling = <String, bool>{}; // source -> fill-back still has work this round

  /// Oldest created_utc (seconds) the round preloads for [f].
  static int horizon(Follow f, int nowMs) =>
      (nowMs - (f.kind == FollowKind.sub ? subWindow : userWindow).inMilliseconds) ~/ 1000;

  static String _unitKey(String source, Follow f) => '$source|${f.key}';

  static Future<FollowState> _state(String source, Follow f) async => FollowState.decode((await Db.cursor(_unitKey(source, f))).$1);
  static Future<void> _save(String source, Follow f, FollowState s) => Db.setCursor(_unitKey(source, f), s.encode());

  /// True once a refresh round was started for [source] this session.
  static bool started(String source) => _round.containsKey(source);

  /// Next batch for [source]; returns new post count, -1 when every entry is exhausted.
  static Future<int> fetchMore(String source, {bool fromStart = false, DateTime? now}) =>
      _locked(() => _fetchMore(source, fromStart: fromStart, now: now));

  static Future<int> _fetchMore(String source, {bool fromStart = false, DateTime? now}) async {
    final pid = followingProfile(source);
    if (pid == null) return -1;
    final follows = await FollowStore.follows(pid);
    if (follows.isEmpty) {
      followingStatus.value = 'This profile has no subreddits or users yet';
      await Db.setCursor(source, null);
      return -1;
    }
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    _sets[pid] = (
      {for (final f in follows) if (f.kind == FollowKind.sub) f.name.toLowerCase()},
      {for (final f in follows) if (f.kind == FollowKind.user) f.name.toLowerCase()},
    );
    final states = {for (final f in follows) f: await _state(source, f)};

    // Start a refresh round on pull-to-refresh or the first call this session.
    if (fromStart || !_round.containsKey(source)) {
      final stale = follows.where((f) => t - states[f]!.at >= freshFor.inMilliseconds).toList()
        ..sort((a, b) => states[a]!.at.compareTo(states[b]!.at));
      _round[source] = stale;
      _checked[source] = (follows.length - stale.length, follows.length, 0);
      _retried[source] = {};
      _filled[source] = {};
    }
    final queue = _round[source]!;
    var (checked, total, failed) = _checked[source]!;
    total = follows.length;
    var added = 0;
    var used = 0;

    Future<void> save(Follow f, List<Map<String, dynamic>> rows) async {
      final posts = <Post>[];
      for (final d in rows) {
        final p = Post.fromJson(slimPost(d));
        if (p != null) posts.add(p);
      }
      await Db.savePosts(source, posts);
      added += posts.length;
      if (posts.isNotEmpty) version.value++;
    }

    final filled = _filled.putIfAbsent(source, () => {});
    // Entries whose posts don't reach back to their window yet, newest gap first.
    List<Follow> toFill() => follows.where((f) {
          final s = states[f]!;
          return !s.done && s.oldest != null && s.oldest! > horizon(f, t) && (filled[f.key] ?? 0) < fillPages;
        }).toList()
          ..sort((a, b) => states[b]!.oldest!.compareTo(states[a]!.oldest!));

    void status([int? fillLeft]) {
      _checked[source] = (checked, total, failed);
      final fl = failed > 0 ? ' · $failed failed' : '';
      if (queue.isNotEmpty) {
        final mins = (queue.length * (gap.inMilliseconds + 1500) / 60000).ceil();
        followingStatus.value = 'Checked $checked of $total$fl · ~$mins min left';
      } else if (fillLeft != null && fillLeft > 0) {
        followingStatus.value = 'All $total checked$fl · filling back: $fillLeft to go';
      } else {
        followingStatus.value = 'All $total checked$fl · scroll for older posts';
      }
    }

    // 1) refresh: newest posts first
    while (queue.isNotEmpty && used < budget) {
      final f = queue.removeAt(0);
      final s = states[f]!;
      used++;
      try {
        final rows = await _paced(f, after: s.newest, limit: s.newest == null ? pageSize : refreshSize);
        await save(f, rows);
        final ts = [for (final r in rows) _ts(r)].where((x) => x > 0).toList();
        if (ts.isNotEmpty) {
          final hi = ts.reduce((a, b) => a > b ? a : b), lo = ts.reduce((a, b) => a < b ? a : b);
          if (s.newest == null || hi > s.newest!) s.newest = hi;
          if (s.oldest == null) {
            s.oldest = lo;
            s.done = rows.length < pageSize;
          }
        } else if (s.newest == null) {
          s.done = true; // nothing at all for this entry
        }
        s.at = t;
        await _save(source, f, s);
        checked++;
      } catch (e) {
        // First failure: try this entry again at the end of the round (after a pause if the archive said
        // to slow down). Second failure: count it and move on; the next round retries it.
        if (_retried.putIfAbsent(source, () => {}).add(f.key)) {
          queue.add(f); // the gap already grew if the archive said to slow down
        } else {
          failed++;
          checked++;
        }
      }
      status();
    }

    // 2) fill-back to the window, then 3) page back on scroll: entries with the newest unexplored history
    // first, so the feed stays roughly in date order.
    var fill = queue.isEmpty ? toFill() : <Follow>[];
    if (queue.isEmpty && used < budget) {
      final open = fill.isNotEmpty
          ? fill
          : (follows.where((f) => !states[f]!.done && states[f]!.oldest != null).toList()
            ..sort((a, b) => states[b]!.oldest!.compareTo(states[a]!.oldest!)));
      final filling = fill.isNotEmpty;
      for (final f in open.take(budget - used)) {
        final s = states[f]!;
        if (filling) filled[f.key] = (filled[f.key] ?? 0) + 1; // a failed page counts too, so errors can't loop
        try {
          final rows = await _paced(f, before: s.oldest, limit: pageSize);
          await save(f, rows);
          final ts = [for (final r in rows) _ts(r)].where((x) => x > 0).toList();
          if (ts.isNotEmpty) s.oldest = ts.reduce((a, b) => a < b ? a : b);
          s.done = rows.length < pageSize || ts.isEmpty;
          await _save(source, f, s);
        } catch (_) {
          // try again on a later call (the gap already grew if it was a slow-down)
        }
      }
    }

    if (queue.isEmpty) fill = toFill();
    _filling[source] = fill.isNotEmpty;
    status(fill.length);
    final allDone = queue.isEmpty && follows.every((f) => states[f]!.done);
    await Db.setCursor(source, allDone ? null : 'more');
    return allDone && added == 0 ? -1 : added;
  }

  /// True while a refresh round still has entries to check or fill back (it keeps going on its own until done).
  static bool refreshing(String source) => (_round[source]?.isNotEmpty ?? false) || (_filling[source] ?? false);

  static int _ts(Map d) {
    final v = d['created_utc'];
    return v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  }

  @visibleForTesting
  static void debugReset() {
    _round.clear();
    _checked.clear();
    _retried.clear();
    _filled.clear();
    _filling.clear();
    _last = null;
    gap = minGap;
    followingKind.value = 0;
    FollowingRefresher.stop();
    followingStatus.value = null;
  }
}

/// Runs a profile's refresh round to the end, independent of any screen: switching tabs or opening the
/// viewer doesn't stop it. One source at a time; starting another one stops the previous loop.
class FollowingRefresher {
  static String? _source;
  static int _gen = 0;

  static bool running(String source) => _source == source;

  static void start(String source, {bool fromStart = false}) {
    if (_source == source && !fromStart) return;
    final gen = ++_gen;
    _source = source;
    () async {
      var first = true;
      try {
        while (gen == _gen) {
          final n = await Following.fetchMore(source, fromStart: first && fromStart);
          first = false;
          if (n < 0 || !Following.refreshing(source)) break;
        }
      } catch (_) {
        // a failed batch ends this loop; the next refresh or scroll starts it again
      } finally {
        if (gen == _gen) _source = null;
      }
    }();
  }

  static void stop() {
    _gen++;
    _source = null;
  }
}
