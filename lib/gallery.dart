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

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _headerH = 28.0;
const _cols = 3;

class _Section {
  final int year, month;
  final List<int> idx = []; // indices into entries
  _Section(this.year, this.month);
  String get label => '${_months[month - 1]} $year';
}

class GalleryScreen extends StatefulWidget {
  final String? title;
  final bool sources;
  final Widget? leading;
  final List<Widget> actions;
  const GalleryScreen({super.key, this.title, this.sources = true, this.leading, this.actions = const []});
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final sc = ScrollController();
  List<Entry> entries = [];
  List<_Section> sections = [];
  List<Post> _all = [];
  Map<String, List<Post>> copies = {};
  bool loading = false, done = false, seeking = false, bulk = false, cancel = false;
  int bulkPages = 0;
  String? error, seekMsg;

  bool _active = true;
  String? _loaded;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final a = TickerMode.valuesOf(context).enabled;
    if (a && !_active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_loaded != effectiveSource()) { _switch(); } else { _rebuild(); }
      });
    }
    _active = a;
  }

  @override
  void initState() {
    super.initState();
    currentSource.addListener(_switch);
    subSort.addListener(_switchSort);
    viewFilters.addListener(_rebuild);
    Dedupe.version.addListener(_rebuild);
    dateRange.addListener(_seek);
    sc.addListener(() {
      if (sc.position.pixels > sc.position.maxScrollExtent - 1200) _more();
    });
    _switch();
  }

  @override
  void dispose() {
    currentSource.removeListener(_switch);
    subSort.removeListener(_switchSort);
    viewFilters.removeListener(_rebuild);
    Dedupe.version.removeListener(_rebuild);
    dateRange.removeListener(_seek);
    super.dispose();
  }

  void _switchSort() {
    if (!_active) return;
    if (currentSource.value.startsWith('r/') || currentSource.value.startsWith('u/')) _switch();
  }

  Future<void> _seek() async {
    if (!_active) return;
    final r = dateRange.value;
    if (r == null || seeking) return;
    final src = effectiveSource();
    setState(() { seeking = true; seekMsg = 'Looking for older posts…'; });
    final err = await pageUntil(src, r.start, (pages, oldest) {
      if (!mounted) return;
      setState(() => seekMsg = 'Fetched $pages page${pages == 1 ? '' : 's'}'
          '${oldest == null ? '' : ' · back to ${oldest.day}/${oldest.month}/${oldest.year}'}');
    });
    if (!mounted) return;
    final (_, d) = await Db.cursor(src);
    if (src == effectiveSource()) done = d;
    await _fromDb();
    setState(() { seeking = false; seekMsg = null; if (err != null) error = err; });
  }

  Future<void> _switch() async {
    if (!_active) return;
    final src = effectiveSource();
    _loaded = src;
    await _fromDb();
    final (_, d) = await Db.cursor(src);
    if (!mounted || src != effectiveSource()) return;
    setState(() => done = d);
    if (entries.isEmpty) {
      await _more();
    } else {
      _refreshTop();
    }
  }

  Future<void> _fromDb() async {
    final src = effectiveSource();
    final all = await Db.load(src);
    if (src != effectiveSource()) return;
    _all = all;
    await Dedupe.warm(all);
    _rebuild();
  }

  void _rebuild() {
    if (!_active) return;
    var shown = _all.where(matches).toList();
    var cp = <String, List<Post>>{};
    if (dupesOn && mediaFilter.value != MediaFilter.text) (shown, cp) = Dedupe.collapse(shown);
    copies = cp;
    final e = flatten(shown);
    final secs = <_Section>[];
    for (var i = 0; i < e.length; i++) {
      final d = e[i].post.date.toLocal();
      if (secs.isEmpty || secs.last.year != d.year || secs.last.month != d.month) secs.add(_Section(d.year, d.month));
      secs.last.idx.add(i);
    }
    if (mounted) setState(() { entries = e; sections = secs; });
    if (mounted && sc.hasClients && sc.offset > 0 && sc.position.maxScrollExtent < sc.offset) sc.jumpTo(0);
  }

  Future<void> _refreshTop() async {
    try {
      await Api.fetchMore(effectiveSource(), fromStart: true);
      await _fromDb();
    } catch (e) {
      if (mounted) setState(() => error = 'Refresh failed: ${'$e'.replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _more() async {
    if (loading || done) return;
    final src = effectiveSource();
    setState(() { loading = true; error = null; });
    var again = false;
    try {
      final n = await Api.fetchMore(src);
      if (src != effectiveSource()) {
        // Switched source mid-load; the new source's first page was skipped by the guard above.
        again = entries.isEmpty;
      } else {
        if (n < 0) done = true;
        final (_, d) = await Db.cursor(src);
        done = d;
        await _fromDb();
        // Keep fetching if this page had no media but more pages exist.
        again = !done && sc.hasClients && sc.position.maxScrollExtent < 600 && dateRange.value == null;
      }
    } catch (e) {
      if (src == effectiveSource()) error = 'Couldn\'t load more: ${'$e'.replaceFirst('Exception: ', '')}';
    } finally {
      if (mounted) setState(() => loading = false);
    }
    if (again && mounted) await _more();
  }

  Future<void> _loadAll() async {
    final src = effectiveSource();
    setState(() { bulk = true; cancel = false; bulkPages = 0; });
    while (!done && mounted && error == null && !cancel && src == effectiveSource()) {
      await _more();
      if (mounted) setState(() => bulkPages++);
    }
    if (mounted) setState(() => bulk = false);
  }

  String get _oldest {
    if (_all.isEmpty) return '';
    final d = _all.map((p) => p.created).reduce((a, b) => a < b ? a : b);
    final t = DateTime.fromMillisecondsSinceEpoch(d * 1000).toLocal();
    return ' · back to ${t.day}/${t.month}/${t.year}';
  }

  double _offsetOf(int s, double w) {
    final cell = w / _cols;
    var off = 0.0;
    for (var i = 0; i < s; i++) {
      off += _headerH + (sections[i].idx.length / _cols).ceil() * cell;
    }
    return off;
  }

  void _jump() {
    final years = <int, List<int>>{};
    for (var i = 0; i < sections.length; i++) {
      years.putIfAbsent(sections[i].year, () => []).add(i);
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: glassFill(context),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, c) => ListView(controller: c, children: [
          if (!done)
            ListTile(
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('Fetch older posts (all pages)'),
              subtitle: const Text('Adds older months to this list'),
              onTap: () { Navigator.pop(ctx); _loadAll(); },
            ),
          for (final y in years.keys) ...[
            Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 2), child: Text('$y', style: Theme.of(ctx).textTheme.titleMedium)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final si in years[y]!)
                  ActionChip(
                    label: Text('${_months[sections[si].month - 1].substring(0, 3)} (${sections[si].idx.length})'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      final w = MediaQuery.of(context).size.width;
                      sc.jumpTo(_offsetOf(si, w).clamp(0, sc.position.maxScrollExtent));
                    },
                  ),
              ]),
            ),
          ],
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final deep = isDeep(effectiveSource());
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: RefreshIndicator(
        onRefresh: _refreshTop,
        child: CustomScrollView(
          controller: sc,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(pinned: true, flexibleSpace: const GlassBar(), 
        leading: widget.leading,
        title: Text(widget.title ?? 'Hobee', style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          ...widget.actions,
          IconButton(icon: const Icon(Icons.calendar_month), tooltip: 'Jump to month', onPressed: sections.isEmpty ? null : _jump),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => showActionsSheet(context,
                onRefresh: _refreshTop,
                onTop: () => sc.hasClients ? sc.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut) : null,
                onRandom: () {
                  if (entries.isEmpty) return;
                  final i = Random().nextInt(entries.length);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => Viewer(entries: entries, start: i)));
                }),
          ),
        ],
        bottom: SourceAndFilterBar(sources: widget.sources),
      ),
            if (deep)
              SliverToBoxAdapter(
                child: DeepStatusPanel(
                  all: _all, bulk: bulk, done: done, bulkPages: bulkPages, oldest: _oldest, error: error,
                  onRetry: () { setState(() => error = null); _refreshTop(); },
                  onFetchAll: _loadAll,
                  onCancel: () => setState(() => cancel = true),
                  onShowText: () { mediaFilter.value = MediaFilter.text; applyLayout(PostLayout.card); },
                ),
              ),
            if (seeking)
              SliverToBoxAdapter(
                child: Column(children: [
                  const LinearProgressIndicator(),
                  Padding(padding: const EdgeInsets.all(8), child: Text(seekMsg ?? '', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12))),
                ]),
              ),
            for (final s in sections)
              SliverMainAxisGroup(slivers: [
                SliverPersistentHeader(pinned: true, delegate: _Header(s.label, '${s.idx.length}', cs)),
                SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: _cols, mainAxisSpacing: 0, crossAxisSpacing: 0),
                  delegate: SliverChildBuilderDelegate((_, j) {
                    final i = s.idx[j];
                    final e = entries[i];
                    final dup = copies[e.post.id];
                    return GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Viewer(entries: entries, start: i))),
                      onLongPress: dup == null ? null : () => showCopiesSheet(context, dup, (p) {
                        final pe = flatten([p]);
                        if (pe.isNotEmpty) Navigator.push(context, MaterialPageRoute(builder: (_) => Viewer(entries: pe, start: 0)));
                      }),
                      child: Padding(
                        padding: const EdgeInsets.all(1),
                        child: Stack(fit: StackFit.expand, children: [
                          if (deep)
                            ArchiveImage(key: ValueKey(e.item.thumb), post: e.post, item: e.item, cacheWidth: 360, deep: true)
                          else
                          e.item.thumb.isEmpty
                              ? Container(color: cs.surfaceContainerHighest, child: const Icon(Icons.movie))
                              : Image.network(e.item.thumb, fit: BoxFit.cover, cacheWidth: 360,
                                  errorBuilder: (_, _, _) => Container(color: cs.surfaceContainerHighest, child: const Icon(Icons.broken_image))),
                          if (deep) Positioned(left: 4, bottom: 4, child: StatusBadge(e.post)),
                          if (e.item.type != MediaType.image)
                            const Positioned(right: 4, top: 4, child: _Badge(Icons.play_arrow_rounded)),
                          if (e.post.media.length > 1)
                            const Positioned(left: 4, top: 4, child: _Badge(Icons.collections_rounded)),
                          if (dup != null && e.index == 0) Positioned(right: 4, bottom: 4, child: DupBadge(dup.length)),
                        ]),
                      ),
                    );
                  }, childCount: s.idx.length),
                ),
              ]),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: loading
                      ? const CircularProgressIndicator()
                      : error != null
                          ? Column(children: [Text(error!, textAlign: TextAlign.center), TextButton(onPressed: _more, child: const Text('Retry'))])
                          : done
                              ? (entries.isEmpty && mediaFilter.value == MediaFilter.text && _all.any((p) => p.media.isEmpty)
                                  ? TextButton.icon(onPressed: () => applyLayout(PostLayout.card), icon: const Icon(Icons.view_agenda_outlined), label: const Text('Text posts show in Card / Compact layout'))
                                  : Text(entries.isEmpty ? (_all.isEmpty ? (deep ? 'No archived posts' : 'No media here') : (_all.every((p) => p.media.isEmpty) ? 'All posts are text, no media' : 'Nothing matches these filters')) : 'No more posts'))
                              : TextButton(onPressed: _more, child: const Text('Load more')),
                ),
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 4)),
          ],
        ),
      ),
    );
  }
}

class _Header extends SliverPersistentHeaderDelegate {
  final String label, count;
  final ColorScheme cs;
  _Header(this.label, this.count, this.cs);
  @override
  double get maxExtent => _headerH;
  @override
  double get minExtent => _headerH;
  @override
  bool shouldRebuild(_Header o) => o.label != label || o.count != count || o.cs != cs;
  @override
  Widget build(BuildContext context, double shrink, bool overlaps) => Container(
        color: cs.surface.withValues(alpha: 0.55),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        child: Row(children: [
          Container(width: 4, height: 16, color: cs.primary),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(count, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
        ]),
      );
}

class _Badge extends StatelessWidget {
  final IconData icon;
  const _Badge(this.icon);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
        child: Icon(icon, color: Colors.white, size: 16),
      );
}
