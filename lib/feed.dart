import 'dart:math';
import 'package:flutter/material.dart';
import 'glass.dart';
import 'api.dart';
import 'archive.dart';
import 'archive_ui.dart';
import 'db.dart';
import 'dedupe.dart';
import 'filters.dart';
import 'models.dart';
import 'source_bar.dart';
import 'viewer.dart';

class FeedScreen extends StatefulWidget {
  final String? title;
  final bool sources;
  final Widget? leading;
  final List<Widget> actions;
  const FeedScreen({super.key, this.title, this.sources = true, this.leading, this.actions = const []});
  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final sc = ScrollController();
  final pc = PageController();

  void _open(int i) => Navigator.push(context, MaterialPageRoute(builder: (_) => Viewer(entries: flatten(posts), start: flatten(posts.sublist(0, i)).length))).then((_) => _apply());
  List<Post> _all = [];
  List<Post> posts = [];
  Map<String, List<Post>> copies = {};

  List<Post> _filter(List<Post> all) {
    var shown = all.where(matches).toList();
    var cp = <String, List<Post>>{};
    if (dupesOn && mediaFilter.value != MediaFilter.text) (shown, cp) = Dedupe.collapse(shown);
    copies = cp;
    return shown;
  }
  bool loading = false, done = false;
  String? error;

  bool _active = true;
  String? _loaded;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final a = TickerMode.valuesOf(context).enabled;
    if (a && !_active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_loaded != effectiveSource()) { _load(); } else { _apply(); }
      });
    }
    _active = a;
  }

  @override
  void initState() {
    super.initState();
    currentSource.addListener(_load);
    subSort.addListener(_load);
    viewFilters.addListener(_apply);
    Dedupe.version.addListener(_apply);
    postLayout.addListener(_apply);
    sc.addListener(() {
      if (sc.position.pixels > sc.position.maxScrollExtent - 800) _more();
    });
    _load();
  }

  @override
  void dispose() {
    currentSource.removeListener(_load);
    subSort.removeListener(_load);
    viewFilters.removeListener(_apply);
    Dedupe.version.removeListener(_apply);
    postLayout.removeListener(_apply);
    super.dispose();
  }

  Future<void> _load() async {
    if (!_active) return;
    final src = effectiveSource();
    _loaded = src;
    final p = await Db.load(src);
    await Dedupe.warm(p);
    final (_, d) = await Db.cursor(src);
    if (src != effectiveSource()) return;
    if (mounted) setState(() { _all = p; posts = _filter(p); done = d; error = null; });
    if (p.isEmpty) _more();
  }

  Future<void> _more() async {
    if (loading || done) return;
    setState(() { loading = true; error = null; });
    final src = effectiveSource();
    var switched = false;
    try {
      await Api.fetchMore(src);
      final (_, d) = await Db.cursor(src);
      final p = await Db.load(src);
      if (src == effectiveSource()) { _all = p; posts = _filter(p); done = d; }
      else { switched = true; }
    } catch (e) {
      if (src == effectiveSource()) error = 'Couldn\'t load more: ${'$e'.replaceFirst('Exception: ', '')}';
    } finally {
      if (mounted) setState(() => loading = false);
    }
    // Source changed while this page was loading: the new source's first page was skipped by the guard.
    if (switched && mounted && _all.isEmpty) _more();
  }

  Future<void> _refresh() async {
    try {
      await Api.fetchMore(effectiveSource(), fromStart: true);
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = 'Refresh failed: ${'$e'.replaceFirst('Exception: ', '')}');
    }
    await _load();
  }

  void _apply() {
    if (!_active) return;
    if (mounted) setState(() => posts = _filter(_all));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final deep = isDeep(effectiveSource());
    final pad = bodyPadding(context, h: 0, v: 4);
    return Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(flexibleSpace: const GlassBar(), 
        leading: widget.leading,
        title: Text(widget.title ?? 'Hobee', style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          ...widget.actions,
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => showActionsSheet(context,
                onRefresh: _refresh,
                onTop: () {
                  if (sc.hasClients) sc.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                  if (pc.hasClients) pc.jumpToPage(0);
                },
                onRandom: () {
                  if (posts.isEmpty) return;
                  _open(Random().nextInt(posts.length));
                }),
          ),
        ],
        bottom: SourceAndFilterBar(sources: widget.sources),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: postLayout.value == PostLayout.slides ? _slides(cs) : ListView.builder(
          controller: sc,
          padding: pad,
          itemCount: posts.length + 1 + (deep ? 1 : 0),
          itemBuilder: (_, i0) {
            if (deep && i0 == 0) {
              return DeepStatusPanel(
                all: _all, bulk: false, done: done, bulkPages: 0, oldest: '', error: error,
                onRetry: () async { await Api.fetchMore(effectiveSource(), fromStart: true).catchError((e) { error = '$e'; return 0; }); await _load(); },
                onFetchAll: _more, onCancel: () {},
                onShowText: () => mediaFilter.value = MediaFilter.text,
              );
            }
            final i = deep ? i0 - 1 : i0;
            if (i == posts.length) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: loading
                      ? const CircularProgressIndicator()
                      : error != null
                          ? TextButton(onPressed: _more, child: Text('Error — retry\n$error', textAlign: TextAlign.center))
                          : done
                              ? Text(posts.isEmpty
                                  ? (_all.isEmpty ? 'Nothing here' : (_all.every((p) => p.media.isEmpty) && mediaFilter.value != MediaFilter.text ? 'All posts are text — pick the Text filter' : 'Nothing matches these filters'))
                                  : 'No more posts')
                              : TextButton(onPressed: _more, child: const Text('Load more')),
                ),
              );
            }
            final p = posts[i];
            final m = p.media.isNotEmpty ? p.media.first : null;
            if (postLayout.value == PostLayout.compact) return _compact(p, i, cs);
            final dup = copies[p.id];
            final self = '${p.raw['selftext'] ?? ''}'.trim();
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              clipBehavior: Clip.antiAlias,
              color: cs.surface.withValues(alpha: 0.7),
              child: InkWell(
                onTap: m == null
                    ? null
                    : () => _open(i),
                onLongPress: dup == null ? null : () => showCopiesSheet(context, dup, (_) => _open(i)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 3),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text('r/${p.subreddit} • ${p.date.toLocal().toString().substring(0, 10)}',
                            style: TextStyle(color: cs.primary, fontSize: 12, fontWeight: FontWeight.w600)),
                        if (isDeep(effectiveSource())) ...[const SizedBox(width: 6), StatusBadge(p)],
                        if (dup != null) ...[const SizedBox(width: 6), DupBadge(dup.length)],
                      ]),
                      const SizedBox(height: 4),
                      Text(p.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                      if (m == null && self.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(self, maxLines: 8, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                      ],
                    ]),
                  ),
                  if (m != null && m.thumb.isNotEmpty)
                    Stack(children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 420),
                        child: isDeep(effectiveSource())
                            ? SizedBox(width: double.infinity, height: 300, child: ArchiveImage(key: ValueKey(m.thumb), post: p, item: m, deep: true))
                            : Image.network(m.thumb, width: double.infinity, fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const SizedBox(height: 0)),
                      ),
                      if (m.type != MediaType.image)
                        const Positioned.fill(child: Center(child: Icon(Icons.play_circle_fill, size: 56, color: Colors.white))),
                      if (p.media.length > 1)
                        Positioned(
                          right: 8, top: 8,
                          child: Chip(label: Text('1/${p.media.length}'), visualDensity: VisualDensity.compact),
                        ),
                    ]),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _compact(Post p, int i, ColorScheme cs) {
    final read = readIds.contains(p.id);
    if (p.media.isEmpty) {
      return ListTile(
        leading: const Icon(Icons.notes),
        title: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: read ? cs.onSurfaceVariant : null)),
        subtitle: Text('r/${p.subreddit} • ${p.date.toLocal().toString().substring(0, 10)}', style: TextStyle(color: cs.primary, fontSize: 12)),
        trailing: isDeep(effectiveSource()) ? StatusBadge(p) : null,
      );
    }
    final m = p.media.first;
    final dup = copies[p.id];
    return InkWell(
      onTap: () => _open(i),
      onLongPress: dup == null ? null : () => showCopiesSheet(context, dup, (_) => _open(i)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 64, height: 64,
              child: Stack(fit: StackFit.expand, children: [
                if (isDeep(effectiveSource()))
                  ArchiveImage(key: ValueKey(m.thumb), post: p, item: m, cacheWidth: 160, deep: true)
                else
                m.thumb.isEmpty
                    ? Container(color: cs.surfaceContainerHighest)
                    : Image.network(m.thumb, fit: BoxFit.cover, cacheWidth: 160, errorBuilder: (_, _, _) => Container(color: cs.surfaceContainerHighest)),
                if (m.type != MediaType.image) const Center(child: Icon(Icons.play_circle_fill, color: Colors.white, size: 24)),
                if (p.media.length > 1) const Positioned(right: 2, top: 2, child: Icon(Icons.collections, color: Colors.white, size: 14)),
                if (dup != null) Positioned(left: 2, bottom: 2, child: DupBadge(dup.length)),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: read ? cs.onSurfaceVariant : null)),
              const SizedBox(height: 4),
              Text('r/${p.subreddit} • ${p.date.toLocal().toString().substring(0, 10)}', style: TextStyle(color: cs.primary, fontSize: 12)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _slides(ColorScheme cs) {
    final posts = this.posts.where((p) => p.media.isNotEmpty).toList();
    if (posts.isEmpty) {
      return ListView(children: [Padding(padding: const EdgeInsets.all(48), child: Center(child: loading ? const CircularProgressIndicator() : const Text('Nothing here')))]);
    }
    return PageView.builder(
      controller: pc,
      scrollDirection: Axis.vertical,
      itemCount: posts.length,
      onPageChanged: (i) {
        markRead(posts[i].id);
        if (i >= posts.length - 3) _more();
      },
      itemBuilder: (_, i) {
        final p = posts[i];
        final m = p.media.first;
        final img = m.type == MediaType.image ? m.url : m.thumb;
        return GestureDetector(
          onTap: () => _open(i),
          child: Container(
            color: Colors.black,
            child: Stack(fit: StackFit.expand, children: [
              if (img.isNotEmpty) Image.network(img, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox()),
              if (m.type != MediaType.image) const Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 72)),
              Positioned(
                left: 0, right: 0, bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                  decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87])),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('r/${p.subreddit}${p.media.length > 1 ? ' • ${p.media.length} items' : ''}', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600, fontSize: 12)),
                    const SizedBox(height: 4),
                    Text(p.title, style: const TextStyle(color: Colors.white, fontSize: 15)),
                  ]),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}
