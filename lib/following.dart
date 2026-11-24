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
///  2. then paging back: the entries whose oldest loaded post is newest go one page further back.
bool isFollowing(String source) => source.startsWith('fol:');
String followingKey(int profile) => 'fol:$profile';
int? followingProfile(String source) => isFollowing(source) ? int.tryParse(source.substring(4)) : null;

/// Progress line for the status bar, e.g. "Checked 40 of 325 · 2 failed".
final followingStatus = ValueNotifier<String?>(null);

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
  /// Arctic Shift answers "slow down" (HTTP 422) at about one request a second, so the feed goes gentler:
  /// at least [gap] between its requests, and a [cooldown] pause after a slow-down before going on.
  static Duration gap = const Duration(seconds: 3);
  static Duration cooldown = const Duration(seconds: 30);
  static DateTime? _last;

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
      return await fetchPage(f, after: after, before: before, limit: limit);
    } finally {
      _last = DateTime.now();
    }
  }

  static bool _busy(Object e) => RegExp(r'slow down|busy|rate|429|timed out|timeout', caseSensitive: false).hasMatch('$e');
  static final _retried = <String, Set<String>>{}; // source -> entries already retried this round

  static final _round = <String, List<Follow>>{}; // source -> entries still to refresh this round
  static final _checked = <String, (int, int, int)>{}; // source -> (checked, total, failed) this round

  static String _unitKey(String source, Follow f) => '$source|${f.key}';

  static Future<FollowState> _state(String source, Follow f) async => FollowState.decode((await Db.cursor(_unitKey(source, f))).$1);
  static Future<void> _save(String source, Follow f, FollowState s) => Db.setCursor(_unitKey(source, f), s.encode());

  /// Next batch for [source]; returns new post count, -1 when every entry is exhausted.
  static Future<int> fetchMore(String source, {bool fromStart = false, DateTime? now}) async {
    final pid = followingProfile(source);
    if (pid == null) return -1;
    final follows = await FollowStore.follows(pid);
    if (follows.isEmpty) {
      followingStatus.value = 'This profile has no subreddits or users yet';
      await Db.setCursor(source, null);
      return -1;
    }
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final states = {for (final f in follows) f: await _state(source, f)};

    // Start a refresh round on pull-to-refresh or the first call this session.
    if (fromStart || !_round.containsKey(source)) {
      final stale = follows.where((f) => t - states[f]!.at >= freshFor.inMilliseconds).toList()
        ..sort((a, b) => states[a]!.at.compareTo(states[b]!.at));
      _round[source] = stale;
      _checked[source] = (follows.length - stale.length, follows.length, 0);
      _retried[source] = {};
    }
    final queue = _round[source]!;
    var (checked, total, failed) = _checked[source]!;
    total = follows.length;
    var added = 0;
    var used = 0;

    Future<void> save(Follow f, List<Map<String, dynamic>> rows) async {
      final posts = <Post>[];
      for (final d in rows) {
        final p = Post.fromJson(d);
        if (p != null) posts.add(p);
      }
      await Db.savePosts(source, posts);
      added += posts.length;
    }

    void status() {
      _checked[source] = (checked, total, failed);
      followingStatus.value = queue.isNotEmpty
          ? 'Checked $checked of $total${failed > 0 ? ' · $failed failed' : ''} · Arctic Shift'
          : 'All $total checked${failed > 0 ? ' · $failed failed' : ''} · scroll for older posts';
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
          queue.add(f);
          if (_busy(e)) await Future.delayed(cooldown);
        } else {
          failed++;
          checked++;
        }
      }
      status();
    }

    // 2) page back: entries with the newest unexplored history first, so the feed stays roughly in date order.
    if (queue.isEmpty && used < budget) {
      final open = follows.where((f) => !states[f]!.done && states[f]!.oldest != null).toList()
        ..sort((a, b) => states[b]!.oldest!.compareTo(states[a]!.oldest!));
      for (final f in open.take(budget - used)) {
        final s = states[f]!;
        try {
          final rows = await _paced(f, before: s.oldest, limit: pageSize);
          await save(f, rows);
          final ts = [for (final r in rows) _ts(r)].where((x) => x > 0).toList();
          if (ts.isNotEmpty) s.oldest = ts.reduce((a, b) => a < b ? a : b);
          s.done = rows.length < pageSize || ts.isEmpty;
          await _save(source, f, s);
        } catch (e) {
          if (_busy(e)) await Future.delayed(cooldown); // try again on a later call
        }
      }
    }

    status();
    final allDone = queue.isEmpty && follows.every((f) => states[f]!.done);
    await Db.setCursor(source, allDone ? null : 'more');
    return allDone && added == 0 ? -1 : added;
  }

  /// True while a refresh round still has entries to check (the grid keeps fetching on its own until done).
  static bool refreshing(String source) => _round[source]?.isNotEmpty ?? false;

  static int _ts(Map d) {
    final v = d['created_utc'];
    return v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  }

  @visibleForTesting
  static void debugReset() {
    _round.clear();
    _checked.clear();
    _retried.clear();
    _last = null;
    followingStatus.value = null;
  }
}
