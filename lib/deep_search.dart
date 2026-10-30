import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import 'accounts.dart';
import 'glass.dart';
import 'filters.dart';
import 'nav.dart';
import 'posts_view.dart';
import 'package:flutter/rendering.dart';
import 'models.dart';
import 'viewer.dart';
import 'sub_search.dart';
import 'sub_users.dart';

/// Deep Search tab: archive lookup of a user's older and deleted posts. Works without login.
class DeepSearchScreen extends StatefulWidget {
  const DeepSearchScreen({super.key});
  @override
  State<DeepSearchScreen> createState() => _DeepSearchScreenState();
}

class _DeepSearchScreenState extends State<DeepSearchScreen> {
  final user = TextEditingController(), sub = TextEditingController();
  String? err;
  String? _key;
  bool subs = false;
  DateTime _since = DateTime.now();

  @override
  void initState() {
    super.initState();
    deepSource.addListener(_r);
    deepReturn.addListener(_r);
    deepSource.addListener(_track);
    mainTab.addListener(_r);
    _track();
    deepPrefill.addListener(_prefill);
    _prefill();
  }

  void _r() => mounted ? setState(() {}) : null;

  /// Time spent per account feeds history and the interest profile.
  void _track() {
    final v = deepSource.value;
    if (v != null && isSubSearch(v)) subs = true;
    final k = v == null || isSubSearch(v) ? null : v.substring(5);
    if (k == _key) return;
    if (_key != null) DeepHistory.leave(_key!, DateTime.now().difference(_since).inSeconds);
    _key = k;
    _since = DateTime.now();
  }

  void _prefill() {
    final p = deepPrefill.value;
    if (p == null) return;
    user.text = p.$1;
    sub.text = p.$2;
    deepPrefill.value = null;
  }

  @override
  void dispose() {
    deepSource.removeListener(_r);
    deepReturn.removeListener(_r);
    deepSource.removeListener(_track);
    mainTab.removeListener(_r);
    deepPrefill.removeListener(_prefill);
    super.dispose();
  }

  void _go() {
    if (cleanSubName.hasMatch(user.text.trim())) {
      final r = user.text.trim().replaceFirst(cleanSubName, '');
      user.clear();
      FocusScope.of(context).unfocus();
      clearFilters();
      resetSubOptions();
      setState(() => subs = true);
      openSubSearch(r);
      return;
    }
    final u = user.text.trim().replaceFirst(cleanUser, '');
    final s = sub.text.trim().replaceFirst(cleanSub, '');
    if (!validName.hasMatch(u)) {
      setState(() => err = 'Enter a valid username');
      return;
    }
    setState(() => err = null);
    FocusScope.of(context).unfocus();
    openDeepSearch(user: u, sub: s);
  }

  /// Back from results: clean form, no query, no filters.
  void _reset() {
    final s = deepSource.value;
    if (s != null && !isSubSearch(s) && backToSub()) return;
    subView.value = 0;
    clearFilters();
    resetSubOptions();
    user.clear();
    sub.clear();
    err = null;
    deepSource.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final src = deepSource.value;
    return PopScope(
      canPop: !(src != null && mainTab.value == 1),
      onPopInvokedWithResult: (did, _) {
        if (!did) _reset();
      },
      child: _layers(src),
    );
  }

  /// Subreddit results stay mounted (offstage) while a profile opened from them is shown,
  /// so back returns to the same list and scroll position without reloading.
  Widget _layers(String? src) {
    final sr = src != null && isSubSearch(src) ? src : deepReturn.value;
    final onSr = sr != null && sr == src;
    return Stack(children: [
      if (sr != null)
        KeyedSubtree(
          key: ValueKey('layer|$sr'),
          child: TickerMode(enabled: onSr, child: Offstage(offstage: !onSr, child: _subResults(sr))),
        ),
      if (!onSr)
        AnimatedSwitcher(
          key: const ValueKey('main'),
          duration: const Duration(milliseconds: 220),
          child: src != null ? _results(src) : _form(context),
        ),
    ]);
  }

  Widget _subResults(String src) {
    final p = subParts(src);
    final title = 'r/${p.sub}${p.q.isEmpty ? '' : ' "${p.q}"'}';
    final back = IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'New subreddit search', onPressed: _reset);
    return SubResultsPane(
      source: src,
      posts: PostsView(
        key: ValueKey(src),
        title: title,
        sources: false,
        header: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.only(top: 4), child: SubViewToggle()),
          SubResultsHeader(current: src),
        ]),
        leading: back,
      ),
      usersBar: AppBar(
        flexibleSpace: const GlassBar(),
        leading: back,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        bottom: const PreferredSize(preferredSize: Size.fromHeight(44), child: Padding(padding: EdgeInsets.only(bottom: 6), child: SubViewToggle())),
      ),
    );
  }

  Widget _results(String src) {
    if (isSubSearch(src)) return _subResults(src);
    final key = src.substring(5);
    return PostsView(
      key: ValueKey(src),
      title: 'u/${key.replaceFirst('@', ' · r/')}',
      sources: false,
      onTitleTap: () => showAccountSwitcher(context, key),
      header: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ProfileHeader(key.split('@').first),
        AccountStrip(current: key),
      ]),
      leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: deepReturn.value != null ? 'Back to r/${subParts(deepReturn.value!).sub}' : 'New deep search',
          onPressed: _reset),
    );
  }

  Widget _form(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      key: const ValueKey('form'),
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(flexibleSpace: const GlassBar(), title: const Text('Deep Search', style: TextStyle(fontWeight: FontWeight.bold))),
      body: ListView(padding: bodyPadding(context), children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, icon: Icon(Icons.person_search), label: Text('Accounts')),
            ButtonSegment(value: true, icon: Icon(Icons.forum_outlined), label: Text('Subreddits')),
          ],
          selected: {subs},
          onSelectionChanged: (s) => setState(() => subs = s.first),
        ),
        const SizedBox(height: 16),
        if (subs) const SubSearchForm() else ...[
        Text('Find a user\'s older and deleted posts from Reddit, RSS, Redlib and public archives. No login needed.',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 16),
        TextField(
          controller: user,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(prefixText: 'u/', labelText: 'Username', hintText: 'or r/name for a subreddit', errorText: err, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: sub,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _go(),
          decoration: const InputDecoration(prefixText: 'r/', labelText: 'Subreddit (optional)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 4),
        ValueListenableBuilder(
          valueListenable: hideDupesDeep,
          builder: (_, v, _) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Hide duplicates'),
            subtitle: const Text('Collapse reposts of the same image/gallery'),
            value: v,
            onChanged: (x) => hideDupesDeep.value = x,
          ),
        ),
        const SizedBox(height: 4),
        FilledButton.icon(onPressed: _go, icon: const Icon(Icons.manage_search), label: const Text('Deep search')),
        const SizedBox(height: 20),
        RecentAccounts(filter: user.text.trim().replaceFirst(cleanUser, '')),
        const SizedBox(height: 16),
        const SuggestedAccounts(),
        ],
      ]),
    );
  }
}

String? _sub(String key) => key.contains('@') ? key.split('@')[1] : null;
void _open(String key) => openDeepSearch(user: key.split('@').first, sub: _sub(key));

Widget avatar(String name, String? url, {double r = 18}) => CircleAvatar(
      radius: r,
      foregroundImage: url == null ? null : NetworkImage(url),
      child: Text(name.isEmpty ? '?' : name[0].toUpperCase(), style: TextStyle(fontSize: r * 0.8)),
    );

/// Recent searches: avatar, posts, last searched, delete one or clear all. Tap switches instantly.
class RecentAccounts extends StatelessWidget {
  final String filter;
  final String? skip;
  final VoidCallback? onPick;
  const RecentAccounts({super.key, this.filter = '', this.skip, this.onPick});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: DeepHistory.changed,
        builder: (_, _, _) {
          final f = filter.toLowerCase();
          final items = DeepHistory.items.where((a) => a.key != skip && (f.isEmpty || a.key.toLowerCase().contains(f))).toList();
          if (items.isEmpty) return const SizedBox.shrink();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('Recent searches', style: Theme.of(context).textTheme.titleSmall)),
              TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(title: const Text('Clear all history?'), actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
                          ]));
                  if (ok == true) DeepHistory.clear();
                },
                child: const Text('Clear all'),
              ),
            ]),
            for (final a in items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: avatar(a.user, a.avatar),
                title: Text(a.label),
                subtitle: Text('${a.posts} posts · ${ago(a.last)}'),
                trailing: IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Remove', onPressed: () => DeepHistory.remove(a.key)),
                onTap: () {
                  onPick?.call();
                  _open(a.key);
                },
              ),
          ]);
        },
      );
}

/// Suggestion list; [similarTo] null means "Suggested for you".
class SuggestedAccounts extends StatefulWidget {
  final String? similarTo;
  final VoidCallback? onPick;
  const SuggestedAccounts({super.key, this.similarTo, this.onPick});
  @override
  State<SuggestedAccounts> createState() => _SuggestedAccountsState();
}

class _SuggestedAccountsState extends State<SuggestedAccounts> {
  List<Suggestion>? list;
  int page = 20;
  Timer? _deb;
  int _req = 0;
  @override
  void initState() {
    super.initState();
    Suggest.changed.addListener(_soon);
    DeepHistory.changed.addListener(_soon);
    // Nothing heavy on open: recents paint first, suggestions follow.
    WidgetsBinding.instance.addPostFrameCallback((_) => _deb = Timer(const Duration(milliseconds: 350), _load));
  }

  @override
  void dispose() {
    _deb?.cancel();
    Suggest.changed.removeListener(_soon);
    DeepHistory.changed.removeListener(_soon);
    super.dispose();
  }

  void _soon() {
    _deb?.cancel();
    _deb = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _load() async {
    final id = ++_req;
    final s = widget.similarTo;
    final r = s == null ? await Suggest.forYou() : await Suggest.similarTo(s);
    if (mounted && id == _req) setState(() => list = r); // stale results dropped
  }

  @override
  Widget build(BuildContext context) {
    final l = list;
    final main = widget.similarTo == null;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final shown = l == null ? const <Suggestion>[] : AccountMeta.visible(l, want: max(40, page));
    if (!main && shown.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(main ? 'Suggested for you' : 'Similar accounts', style: t.titleSmall),
      const SizedBox(height: 6),
      if (l == null)
        const Padding(padding: EdgeInsets.all(12), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))))
      else if (shown.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(AccountMeta.busy ? 'Checking accounts...' : 'No suggestions yet. Search a few accounts and they show up here.',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
        ),
      for (final s in shown.take(page))
        SuggestionCard(
          key: ValueKey(s.user),
          s: s,
          onPick: widget.onPick,
        ),
      if (shown.length > page)
        TextButton(onPressed: () => setState(() => page += 20), child: Text('Show more (${shown.length - page})')),
      if (main && (AccountMeta.busy || Suggest.fetching) && shown.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 4), child: Text('Finding more...', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12))),
    ]);
  }
}

/// Search-engine style card: avatar, name, karma, tags, reason, and a lazy strip of recent thumbs.
class SuggestionCard extends StatefulWidget {
  final Suggestion s;
  final VoidCallback? onPick;
  const SuggestionCard({super.key, required this.s, this.onPick});
  @override
  State<SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends State<SuggestionCard> {
  List<Post>? posts;
  bool open = false;
  Timer? _t;
  @override
  void initState() {
    super.initState();
    posts = AccountPreview.peek(widget.s.user);
    // Only cards that stay on screen a moment load thumbs.
    if (posts == null) _t = Timer(const Duration(milliseconds: 500), _visibleCheck);
  }

  void _visibleCheck() {
    if (!mounted) return;
    final ro = context.findRenderObject();
    final pos = Scrollable.maybeOf(context)?.position;
    if (ro is RenderBox && ro.attached && pos != null) {
      final vp = RenderAbstractViewport.maybeOf(ro);
      if (vp != null) {
        final off = vp.getOffsetToReveal(ro, 0).offset;
        if (off > pos.pixels + pos.viewportDimension + 200 || off + ro.size.height < pos.pixels - 200) {
          _t = Timer(const Duration(milliseconds: 600), _visibleCheck); // still off screen
          return;
        }
      }
    }
    AccountPreview.get(widget.s.user).then((p) {
      if (mounted) setState(() => posts = p);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final cs = Theme.of(context).colorScheme;
    final p = posts;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccountPreviewScreen(user: s.user, reason: s.reason, onPick: widget.onPick))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              avatar(s.user, null),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: GestureDetector(onTap: () => openSuggested(s.user), child: Text('u/${s.user}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, decoration: TextDecoration.underline)))),
                  ]),
                  Text('${_karma(s)}${s.reason}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ]),
              ),
              IconButton(icon: Icon(open ? Icons.expand_less : Icons.expand_more), tooltip: open ? 'Less' : 'More', onPressed: () => setState(() => open = !open)),
            ]),
            const SizedBox(height: 8),
            RepaintBoundary(
              child: p == null
                  ? SizedBox(height: 72, child: Center(child: Text('...', style: TextStyle(color: cs.onSurfaceVariant))))
                  : p.isEmpty
                      ? Text('No media to preview', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
                      : open
                          ? Wrap(spacing: 4, runSpacing: 4, children: [for (final x in p.take(12)) _Thumb(post: x, all: p)])
                          : SizedBox(
                              height: 72,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: min(6, p.length),
                                separatorBuilder: (_, _) => const SizedBox(width: 4),
                                itemBuilder: (_, i) => _Thumb(post: p[i], all: p),
                              ),
                            ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final Post post;
  final List<Post> all;
  const _Thumb({required this.post, required this.all});
  @override
  Widget build(BuildContext context) {
    final m = post.media.first;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return GestureDetector(
      onTap: () => _quick(context, post, all),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(children: [
          Image.network(m.thumb, width: 72, height: 72, fit: BoxFit.cover, cacheWidth: (72 * dpr).round(),
              errorBuilder: (_, _, _) => Container(width: 72, height: 72, color: Colors.black12, child: const Icon(Icons.broken_image, size: 18))),
          if (m.type != MediaType.image) const Positioned(right: 3, bottom: 3, child: Icon(Icons.play_circle_fill, size: 16, color: Colors.white)),
        ]),
      ),
    );
  }
}

/// Quick look at one post; opens the full viewer from there.
void _quick(BuildContext context, Post p, List<Post> all) {
  final m = p.media.first;
  showDialog(
    context: context,
    builder: (c) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.6),
          child: Image.network(m.thumb, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox(height: 120, child: Icon(Icons.broken_image))),
        ),
        Padding(padding: const EdgeInsets.all(10), child: Text(p.title, maxLines: 3, overflow: TextOverflow.ellipsis)),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
          TextButton(
            onPressed: () {
              Navigator.pop(c);
              final e = flatten(all);
              Navigator.push(context, MaterialPageRoute(builder: (_) => Viewer(entries: e, start: max(0, e.indexWhere((x) => x.post.id == p.id)))));
            },
            child: const Text('Open'),
          ),
        ]),
      ]),
    ),
  );
}

/// Full account preview: a scrollable gallery from the cached preview posts.
class AccountPreviewScreen extends StatelessWidget {
  final String user;
  final String reason;
  final VoidCallback? onPick;
  const AccountPreviewScreen({super.key, required this.user, this.reason = '', this.onPick});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('u/$user')),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              icon: const Icon(Icons.manage_search),
              label: const Text('Open full Deep Search'),
              onPressed: () {
                Navigator.pop(context);
                onPick?.call();
                openSuggested(user);
              },
            ),
          ),
        ),
        body: FutureBuilder<List<Post>>(
          future: AccountPreview.get(user),
          builder: (c, snap) {
            final p = snap.data;
            if (p == null) return const Center(child: CircularProgressIndicator());
            if (p.isEmpty) return const Center(child: Text('No media found for this account'));
            final e = flatten(p);
            final dpr = MediaQuery.of(c).devicePixelRatio;
            return CustomScrollView(slivers: [
              if (reason.isNotEmpty) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(12), child: Text(reason))),
              SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 140, mainAxisSpacing: 2, crossAxisSpacing: 2),
                itemCount: e.length,
                itemBuilder: (_, i) => GestureDetector(
                  onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => Viewer(entries: e, start: i))),
                  child: Image.network(e[i].item.thumb, fit: BoxFit.cover, cacheWidth: (140 * dpr).round(),
                      errorBuilder: (_, _, _) => Container(color: Colors.black12)),
                ),
              ),
            ]);
          },
        ),
      );
}

/// Deep Search a suggested account.
void openSuggested(String user) => openDeepSearch(user: user);

String _karma(Suggestion s) {
  final m = AccountMeta.of(s.user);
  final v = m?.total;
  return v == null ? '' : '${fmtKarma(v)} karma · ';
}


/// Range slider that only reports on release; drags stay local so nothing reloads per tick.
class LiveRange extends StatefulWidget {
  final RangeValues values;
  final double min, max;
  final int? divisions;
  final RangeLabels Function(RangeValues) labels;
  final ValueChanged<RangeValues> onEnd;
  const LiveRange({super.key, required this.values, this.min = 0, this.max = 1, this.divisions, required this.labels, required this.onEnd});
  @override
  State<LiveRange> createState() => _LiveRangeState();
}

class _LiveRangeState extends State<LiveRange> {
  RangeValues? drag;
  @override
  Widget build(BuildContext context) {
    final v = drag ?? widget.values;
    return RangeSlider(
      values: v,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      labels: widget.labels(v),
      onChanged: (r) => setState(() => drag = r),
      onChangeEnd: (r) {
        setState(() => drag = null);
        widget.onEnd(r);
      },
    );
  }
}

/// Row above results: similar accounts plus recent ones, one tap to switch.
class AccountStrip extends StatefulWidget {
  final String current;
  const AccountStrip({super.key, required this.current});
  @override
  State<AccountStrip> createState() => _AccountStripState();
}

class _AccountStripState extends State<AccountStrip> {
  List<Suggestion> sim = [];
  @override
  void initState() {
    super.initState();
    Suggest.changed.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    Suggest.changed.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final r = await Suggest.similarTo(widget.current.split('@').first);
    if (mounted) setState(() => sim = r);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: DeepHistory.changed,
        builder: (_, _, _) {
          final recent = DeepHistory.items.where((a) => a.key != widget.current).take(8).toList();
          final sim = AccountMeta.visible(this.sim, want: 10);
          final t = Theme.of(context).textTheme.labelMedium;
          return SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), children: [
              if (sim.isNotEmpty) Center(child: Text('Similar  ', style: t)),
              for (final s in sim.take(10))
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Tooltip(
                    message: '${_karma(s)}${s.reason}',
                    child: ActionChip(avatar: avatar(s.user, null, r: 10), label: Text('u/${s.user}'), onPressed: () => openSuggested(s.user)),
                  ),
                ),
              if (recent.isNotEmpty) Center(child: Text('  Recent  ', style: t)),
              for (final a in recent)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(avatar: avatar(a.user, a.avatar, r: 10), label: Text(a.label), onPressed: () => _open(a.key)),
                ),
            ]),
          );
        },
      );
}

/// Tap the username header: type any new name, or jump to a recent or similar account.
Future<void> showAccountSwitcher(BuildContext context, String current) {
  final ctl = TextEditingController();
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) {
      void close() => Navigator.pop(c);
      void go() {
        final u = ctl.text.trim().replaceFirst(cleanUser, '');
        if (!validName.hasMatch(u)) return;
        close();
        openDeepSearch(user: u);
      }

      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (_, sc) => StatefulBuilder(
            builder: (c2, set) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
              TextField(
                controller: ctl,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (_) => set(() {}),
                onSubmitted: (_) => go(),
                decoration: InputDecoration(
                  prefixText: 'u/',
                  hintText: 'Switch to any username',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(icon: const Icon(Icons.manage_search), onPressed: go),
                ),
              ),
              const SizedBox(height: 12),
              RecentAccounts(filter: ctl.text.trim(), skip: current, onPick: close),
              const SizedBox(height: 12),
              SuggestedAccounts(similarTo: current.split('@').first, onPick: close),
            ]),
          ),
        ),
      );
    },
  );
}
