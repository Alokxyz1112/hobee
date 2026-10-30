import 'dart:async';
import 'package:flutter/material.dart';
import 'accounts.dart';
import 'archive.dart';
import 'db.dart';
import 'filters.dart';
import 'models.dart';
import 'nav.dart';
import 'find.dart';
import 'sub_search.dart';
import 'viewed.dart';

// ---------- open a profile from anywhere ----------

/// One tap: close any pushed screens and open [name]'s Deep Search.
void openAuthor(BuildContext context, String name) {
  if (!canOpenAuthor(name)) return;
  Navigator.of(context).popUntil((r) => r.isFirst);
  openDeepSearch(user: name);
}

bool canOpenAuthor(String n) => validName.hasMatch(n) && n != '[deleted]' && n.toLowerCase() != 'automoderator';

({MediaFilter m, DateTimeRange? d, String q, Set<dynamic> st})? _snap;

/// Wire the save/restore of post filters around a profile opened from subreddit results.
void initSubNav() {
  onLeaveSub = (user) {
    Viewed.mark(user);
    _snap = (m: mediaFilter.value, d: dateRange.value, q: searchQuery.value, st: {...statusFilter.value});
    clearFilters();
  };
}

/// Back from a profile to the same subreddit results (kept alive, same scroll, no reload).
bool backToSub() {
  final r = deepReturn.value;
  if (r == null) return false;
  deepReturn.value = null;
  deepSource.value = r;
  final s = _snap;
  _snap = null;
  // Put the post filters back in place without letting any listener seek or refetch.
  restoringFilters = true;
  try {
    clearFilters();
    if (s != null) {
      mediaFilter.value = s.m;
      dateRange.value = s.d;
      searchQuery.value = s.q;
      statusFilter.value = {...s.st};
    }
  } finally {
    restoringFilters = false;
  }
  final who = Viewed.lastMarked;
  Viewed.lastMarked = null;
  if (who != null && Viewed.hide.value) {
    messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Hid posts by u/$who (viewed)'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(label: 'Undo', onPressed: () => Viewed.unmark(who)),
      ));
  }
  return true;
}

// ---------- avatars and stats (cached) ----------

class UserInfo {
  static final Map<String, Future<String?>> _av = {};
  static final Map<String, Future<Map?>> _st = {};
  static Future<String?> avatar(String n) => _av.putIfAbsent(n.toLowerCase(), () => Archive.avatar(n));
  static Future<Map?> stats(String n) => _st.putIfAbsent(n.toLowerCase(), () => Archive.userStats(n));
}

class UserAvatar extends StatelessWidget {
  final String name;
  final double r;
  const UserAvatar(this.name, {super.key, this.r = 14});
  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: UserInfo.avatar(name),
        builder: (_, s) => CircleAvatar(
          radius: r,
          foregroundImage: s.data == null ? null : NetworkImage(s.data!),
          child: Text(name.isEmpty ? '?' : name[0].toUpperCase(), style: TextStyle(fontSize: r * 0.8)),
        ),
      );
}

/// Obvious one tap author pill: avatar + u/name.
class AuthorChip extends StatelessWidget {
  final String author;
  final bool dark;
  const AuthorChip(this.author, {super.key, this.dark = true});
  @override
  Widget build(BuildContext context) {
    final ok = canOpenAuthor(author);
    final fg = dark ? Colors.white : Theme.of(context).colorScheme.onSurface;
    return Material(
      color: dark ? Colors.white.withValues(alpha: 0.16) : Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: ok ? () => openAuthor(context, author) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (ok) UserAvatar(author, r: 12) else const CircleAvatar(radius: 12, child: Icon(Icons.person_off, size: 14)),
            const SizedBox(width: 6),
            Text('u/$author', style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13)),
            if (ok) Icon(Icons.chevron_right, size: 16, color: fg),
          ]),
        ),
      ),
    );
  }
}

/// Small author label for grid tiles (tap opens the profile).
class TileAuthor extends StatelessWidget {
  final String author;
  const TileAuthor(this.author, {super.key});
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canOpenAuthor(author) ? () => openAuthor(context, author) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(8)),
          child: Text('u/$author', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w600)),
        ),
      );
}

String _n(num v) => v >= 1000000 ? '${(v / 1000000).toStringAsFixed(1)}M' : v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : '$v';

String _age(int sec) {
  final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
  final m = (DateTime.now().year - d.year) * 12 + DateTime.now().month - d.month;
  final t = m >= 12 ? '${m ~/ 12}y ${m % 12}m' : '${m}m';
  return 'since ${d.year}, about $t';
}

/// Profile header: avatar, karma, posts, comments, first seen (Arctic Shift).
class ProfileHeader extends StatelessWidget {
  final String user;
  const ProfileHeader(this.user, {super.key});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(children: [
        UserAvatar(user, r: 22),
        const SizedBox(width: 12),
        Expanded(
          child: FutureBuilder<Map?>(
            future: UserInfo.stats(user),
            builder: (_, s) {
              final m = s.data;
              final style = TextStyle(color: cs.onSurfaceVariant, fontSize: 12);
              if (m == null) {
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('u/$user', style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(s.connectionState == ConnectionState.done ? 'No public stats' : 'Loading stats...', style: style),
                ]);
              }
              int n(Object? v) => v is num ? v.toInt() : 0;
              final first = [n(m['earliest_post_at']), n(m['earliest_comment_at'])].where((x) => x > 0).fold<int>(0, (a, b) => a == 0 || b < a ? b : a);
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('u/$user', style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('${_n(n(m['total_karma']))} karma · ${_n(n(m['num_posts']))} posts · ${_n(n(m['num_comments']))} comments', style: style),
                if (first > 0) Text('Active ${_age(first)}', style: style),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

// ---------- Users view for subreddit results ----------

final subView = ValueNotifier<int>(0); // 0 posts, 1 users

class SubUser {
  final String name;
  int posts = 0, nsfw = 0, latest = 0;
  final kinds = <MediaFilter, int>{};
  final thumbs = <String>[];
  final times = <int>[];
  SubUser(this.name);
  MediaFilter get mostly {
    MediaFilter? best;
    for (final e in kinds.entries) {
      if (best == null || e.value > kinds[best]!) best = e.key;
    }
    return best ?? MediaFilter.text;
  }
}

enum UserSort { posts, karma, latest }

/// Users view options: only the sort order.
class UserFilters {
  final UserSort sort;
  const UserFilters({this.sort = UserSort.posts});
  UserFilters copy({UserSort? sort}) => UserFilters(sort: sort ?? this.sort);
}

final userFilters = ValueNotifier<UserFilters>(const UserFilters());

/// Pure: group posts by author (unit tested).
List<SubUser> groupAuthors(List<Post> posts) {
  final m = <String, SubUser>{};
  for (final p in posts) {
    if (!canOpenAuthor(p.author)) continue;
    final u = m.putIfAbsent(p.author.toLowerCase(), () => SubUser(p.author));
    u.posts++;
    if (p.raw['over_18'] == true) u.nsfw++; // never shown; such posts are dropped when parsed
    if (p.created > u.latest) u.latest = p.created;
    u.times.add(p.created);
    final k = p.media.isEmpty ? (isLink(p) ? MediaFilter.links : MediaFilter.text) : kindOf(p);
    u.kinds[k] = (u.kinds[k] ?? 0) + 1;
    if (u.thumbs.length < 6 && p.media.isNotEmpty && p.media.first.thumb.isNotEmpty) u.thumbs.add(p.media.first.thumb);
  }
  return m.values.toList();
}

/// Pure: drop adult posters and sort. [karmaOf] returns null when unknown; [adult] is true for adult profiles.
List<SubUser> filterUsers(List<SubUser> all, UserFilters f, int? Function(String) karmaOf, {bool Function(String)? adult}) {
  final out = all.where((u) => u.nsfw == 0 && !(adult?.call(u.name) ?? false)).toList();
  int c(SubUser x, SubUser y) => switch (f.sort) {
        UserSort.posts => y.posts.compareTo(x.posts),
        UserSort.latest => y.latest.compareTo(x.latest),
        UserSort.karma => (karmaOf(y.name) ?? -1).compareTo(karmaOf(x.name) ?? -1),
      };
  out.sort(c);
  return out;
}

class SubUsersView extends StatefulWidget {
  final String source;
  const SubUsersView({super.key, required this.source});
  @override
  State<SubUsersView> createState() => _SubUsersViewState();
}

class _SubUsersViewState extends State<SubUsersView> {
  List<SubUser> all = [], shown = [];
  bool loading = true, more = false;
  Timer? _t;
  int _postCount = 0;

  @override
  void initState() {
    super.initState();
    userFilters.addListener(_soon);
    Suggest.changed.addListener(_karmaSoon);
    subView.addListener(_visible);
    Viewed.names.addListener(_apply);
    Viewed.hide.addListener(_apply);
    if (subView.value == 1) _load();
  }

  @override
  void dispose() {
    _t?.cancel();
    userFilters.removeListener(_soon);
    Suggest.changed.removeListener(_karmaSoon);
    subView.removeListener(_visible);
    Viewed.names.removeListener(_apply);
    Viewed.hide.removeListener(_apply);
    super.dispose();
  }

  bool _did = false;
  void _visible() {
    if (subView.value == 1 && !_did) _load();
  }

  /// Built from posts already fetched for this subreddit; no extra network.
  Future<void> _load() async {
    _did = true;
    final posts = await Db.load(widget.source);
    if (!mounted) return;
    _postCount = posts.length;
    all = groupAuthors(posts);
    loading = false;
    _apply();
  }

  int? _karma(String n) => AccountMeta.of(n)?.total;
  bool _adult(String n) => AccountMeta.of(n)?.nsfw == true;

  void _apply() {
    _t?.cancel();
    final f = userFilters.value;
    final base = withoutViewed(all, (u) => u.name, Viewed.names.value, Viewed.hide.value);
    shown = filterUsers(base, f, _karma, adult: _adult);
    // Karma sort needs karma: queue lookups for the top candidates only.
    if (f.sort == UserSort.karma) {
      final need = shown.take(120).map((u) => u.name).where((n) => _karma(n) == null);
      AccountMeta.ensure(need);
    }
    if (mounted) setState(() {});
  }

  void _soon() {
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 200), _apply);
  }

  /// Profile lookups arrive in bursts (karma, adult profiles); refilter once per burst.
  void _karmaSoon() {
    _t ??= Timer(const Duration(milliseconds: 600), () { _t = null; _apply(); });
  }

  Future<void> _fetchMore() async {
    setState(() => more = true);
    try {
      for (var i = 0; i < 3; i++) {
        if (await SubSearch.fetchMore(widget.source) < 0) break;
      }
    } catch (_) {}
    await _load();
    if (mounted) setState(() => more = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final f = userFilters.value;
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            for (final s in UserSort.values)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: ChoiceChip(
                  label: Text(const {UserSort.posts: 'Most posts', UserSort.karma: 'Karma', UserSort.latest: 'Latest'}[s]!),
                  selected: f.sort == s,
                  onSelected: (_) => userFilters.value = f.copy(sort: s),
                ),
              ),
          ]),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
          child: Text(loading ? 'Loading users...' : '${shown.length} of ${all.length} users from $_postCount loaded posts'
              '${f.sort == UserSort.karma && AccountMeta.busy ? ' · checking karma' : ''}',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
        ),
      ),
      SliverList.builder(
        itemCount: shown.length,
        itemBuilder: (_, i) => UserRow(shown[i], key: ValueKey(shown[i].name)),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: more
                ? const CircularProgressIndicator()
                : OutlinedButton.icon(onPressed: _fetchMore, icon: const Icon(Icons.expand_more), label: const Text('Load more posts to find more users')),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 90)),
    ]);
  }

}

class UserRow extends StatefulWidget {
  final SubUser u;
  const UserRow(this.u, {super.key});
  @override
  State<UserRow> createState() => _UserRowState();
}

class _UserRowState extends State<UserRow> {
  @override
  void initState() {
    super.initState();
    // Lazy: only rows that get built ask for karma.
    if (AccountMeta.of(widget.u.name) == null) AccountMeta.ensure([widget.u.name]);
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.u;
    final cs = Theme.of(context).colorScheme;
    final k = AccountMeta.of(u.name)?.total;
    return InkWell(
      onTap: () => openAuthor(context, u.name),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            UserAvatar(u.name, r: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('u/${u.name}', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('${k == null ? 'karma ...' : '${_n(k)} karma'} · ${u.posts} post${u.posts == 1 ? '' : 's'} here · mostly ${mediaFilterLabels[u.mostly]}',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
          if (u.thumbs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 46),
              child: RepaintBoundary(
                child: SizedBox(
                  height: 54,
                  child: Row(children: [
                    for (final t in u.thumbs)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.network(t, width: 54, height: 54, fit: BoxFit.cover, cacheWidth: 120,
                              errorBuilder: (_, _, _) => Container(width: 54, height: 54, color: cs.surfaceContainerHighest)),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Subreddit results with a Posts / Users switch. Both stay alive so switching is instant.
class SubResultsPane extends StatelessWidget {
  final String source;
  final Widget posts;
  final PreferredSizeWidget usersBar;
  const SubResultsPane({super.key, required this.source, required this.posts, required this.usersBar});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: subView,
        builder: (_, v, _) => Stack(children: [
          TickerMode(enabled: v == 0, child: Offstage(offstage: v != 0, child: posts)),
          TickerMode(
            enabled: v == 1,
            child: Offstage(
              offstage: v != 1,
              child: Scaffold(
                backgroundColor: Colors.transparent,
                extendBodyBehindAppBar: true,
                appBar: usersBar,
                body: Padding(padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + usersBar.preferredSize.height), child: SubUsersView(source: source)),
              ),
            ),
          ),
        ]),
      );
}

/// Posts / Users toggle used in both views.
class SubViewToggle extends StatelessWidget {
  const SubViewToggle({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: subView,
        builder: (_, v, _) => Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.center, children: [
          SegmentedButton<int>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [ButtonSegment(value: 0, label: Text('Posts')), ButtonSegment(value: 1, label: Text('Users'))],
            selected: {v},
            onSelectionChanged: (s) => subView.value = s.first,
          ),
          ListenableBuilder(
            listenable: Listenable.merge([Viewed.hide, Viewed.names]),
            builder: (_, _) => FilterChip(
              visualDensity: VisualDensity.compact,
              label: Text('Hide viewed${Viewed.names.value.isEmpty ? '' : ' (${Viewed.names.value.length})'}'),
              selected: Viewed.hide.value,
              onSelected: (b) => Viewed.hide.value = b,
            ),
          ),
        ]),
      );
}
