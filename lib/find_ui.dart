import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'sub_users.dart';
import 'keyword_ui.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'archive_ui.dart';
import 'db.dart';
import 'dedupe.dart';
import 'filters.dart';
import 'find.dart';
import 'glass.dart';
import 'models.dart';
import 'viewer.dart';

/// Fade plus a small rise, used for search screens.
Route<T> fadeRoute<T>(Widget w) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => w,
      transitionsBuilder: (_, a, _, c) {
        final t = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
        return FadeTransition(opacity: t, child: SlideTransition(position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(t), child: c));
      },
    );

/// App bar title; tappable (with a little arrow) when [onTap] is set.
class TitleButton extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  const TitleButton(this.text, {super.key, this.onTap});
  @override
  Widget build(BuildContext context) {
    final t = Text(text, style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis);
    if (onTap == null) return t;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [Flexible(child: t), const Icon(Icons.expand_more, size: 20)]),
      ),
    );
  }
}

/// Search box bound to [searchQuery], filters as you type (100 ms debounce).
class InstantSearchField extends StatefulWidget {
  const InstantSearchField({super.key});
  @override
  State<InstantSearchField> createState() => _InstantSearchFieldState();
}

class _InstantSearchFieldState extends State<InstantSearchField> {
  late final c = TextEditingController(text: searchQuery.value);
  Timer? _t;

  @override
  void initState() {
    super.initState();
    searchQuery.addListener(_sync);
  }

  void _sync() {
    if (c.text.trim() != searchQuery.value) {
      _t?.cancel();
      c.text = searchQuery.value;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _t?.cancel();
    searchQuery.removeListener(_sync);
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SearchBox(
        controller: c,
        onChanged: (v) {
          setState(() {});
          _t?.cancel();
          _t = Timer(const Duration(milliseconds: 250), () => searchQuery.value = v.trim());
        },
        onClear: () {
          _t?.cancel();
          c.clear();
          searchQuery.value = '';
        },
      );
}

class SearchBox extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool autofocus;
  final String hint;
  const SearchBox({super.key, required this.controller, required this.onChanged, required this.onClear, this.autofocus = false, this.hint = 'Search titles, text, subs, users, links'});
  @override
  Widget build(BuildContext context) => Glass(
        radius: BorderRadius.circular(22),
        child: TextField(
          controller: controller,
          autofocus: autofocus,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            border: InputBorder.none,
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: controller.text.isEmpty ? null : IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Clear', onPressed: onClear),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      );
}

/// Text with search matches highlighted (accent-insensitive). Uses the live query unless [terms] is given.
class HighlightText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final List<String>? terms;
  const HighlightText(this.text, {super.key, this.style, this.maxLines, this.terms});
  @override
  Widget build(BuildContext context) {
    final r = matchRanges(text, terms ?? searchTerms);
    final of = maxLines == null ? null : TextOverflow.ellipsis;
    if (r.isEmpty) return Text(text, style: style, maxLines: maxLines, overflow: of);
    if (terms == null) {
      return GestureDetector(onLongPress: () => showBoostSheet(context), child: _rich(context, r, of));
    }
    return _rich(context, r, of);
  }

  Widget _rich(BuildContext context, List<(int, int)> r, TextOverflow? of) {
    final cs = Theme.of(context).colorScheme;
    final hi = TextStyle(backgroundColor: cs.primary.withValues(alpha: 0.28), fontWeight: FontWeight.w700);
    final spans = <TextSpan>[];
    var at = 0;
    for (final (a, b) in r) {
      if (a > at) spans.add(TextSpan(text: text.substring(at, a)));
      spans.add(TextSpan(text: text.substring(a, b), style: hi));
      at = b;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(style: style, children: spans), maxLines: maxLines, overflow: of);
  }
}

void openPost(BuildContext context, Post p) {
  if (p.media.isNotEmpty) {
    markRead(p.id);
    Navigator.push(context, MaterialPageRoute(builder: (_) => Viewer(entries: flatten([p]), start: 0)));
    return;
  }
  final u = isSelfPost(p) ? 'https://www.reddit.com${p.permalink}' : linkUrl(p);
  if (u.startsWith('http')) launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
}

/// Long-press menu for any tile or row.
Future<void> showTileMenu(BuildContext context, Post p, MediaItem? item, List<Post>? dup) => showModalBottomSheet(
      context: context,
      backgroundColor: glassFill(context),
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (item != null && item.thumb.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.image_search),
              title: const Text('Find matches'),
              subtitle: const Text('Same or look-alike pics in everything saved'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, fadeRoute(PhotoMatchScreen(fromPost: p, fromItem: item)));
              },
            ),
          if (dup != null)
            ListTile(
              leading: const Icon(Icons.filter_none),
              title: Text('Show copies (${dup.length})'),
              onTap: () {
                Navigator.pop(ctx);
                showCopiesSheet(context, dup, (c) => openPost(context, c));
              },
            ),
          if (p.author.isNotEmpty && p.author != '[deleted]')
            ListTile(
              leading: const Icon(Icons.manage_search),
              title: Text('Open u/${p.author}'),
              subtitle: const Text('All their posts in Deep Search'),
              onTap: () {
                Navigator.pop(ctx);
                openAuthor(context, p.author);
              },
            ),
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: const Text('Open on Reddit'),
            onTap: () {
              Navigator.pop(ctx);
              launchUrl(Uri.parse('https://www.reddit.com${p.permalink}'), mode: LaunchMode.externalApplication);
            },
          ),
        ]),
      ),
    );

/// System photo picker, then show posts with the same picture.
Future<void> findPhotoFromPicker(BuildContext context) async {
  final XFile? f;
  try {
    f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512);
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn\'t open photos: $e')));
    return;
  }
  if (f == null || !context.mounted) return;
  final bytes = await f.readAsBytes();
  if (!context.mounted) return;
  Navigator.push(context, fadeRoute(PhotoMatchScreen(picked: bytes)));
}

class _Hit {
  final Post post;
  final int index, bits;
  _Hit(this.post, this.index, this.bits);
}

/// Posts whose image matches a picked photo or a tile, ranked by dHash distance.
class PhotoMatchScreen extends StatefulWidget {
  final Uint8List? picked;
  final Post? fromPost;
  final MediaItem? fromItem;
  const PhotoMatchScreen({super.key, this.picked, this.fromPost, this.fromItem});
  @override
  State<PhotoMatchScreen> createState() => _PhotoMatchScreenState();
}

class _PhotoMatchScreenState extends State<PhotoMatchScreen> {
  int? hash;
  String? error;
  final hits = <String, _Hit>{}; // post id -> best hit
  int todo = 0, done = 0;
  bool scanning = false, stopped = false, loaded = false;
  bool closeOnly = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    stopped = true;
    super.dispose();
  }

  void _check(Post p, int i, int? h) {
    if (h == null || hash == null) return;
    final b = Dedupe.hamming(h, hash!);
    if (b > similarBits) return;
    final cur = hits[p.id];
    if (cur == null || b < cur.bits) hits[p.id] = _Hit(p, i, b);
  }

  Future<void> _run() async {
    try {
      hash = widget.picked != null ? await compute(dHash, widget.picked!) : await Dedupe.hashFor(widget.fromItem!.thumb);
    } catch (_) {}
    if (hash == null) {
      if (mounted) setState(() => error = 'Couldn\'t read that picture');
      return;
    }
    final all = await Db.loadEverything();
    await Dedupe.warm(all);
    final missing = <(Post, int, String)>[];
    for (final p in all) {
      final ms = p.media.take(Dedupe.maxPerPost).toList();
      for (var i = 0; i < ms.length; i++) {
        final t = ms[i].thumb;
        if (t.isEmpty) continue;
        if (Dedupe.known(t)) {
          _check(p, i, Dedupe.cachedHash(t));
        } else {
          missing.add((p, i, t));
        }
      }
    }
    if (!mounted) return;
    setState(() { loaded = true; todo = missing.length; scanning = missing.isNotEmpty; });
    // Hash what's missing, a few at a time, showing results as they land.
    var next = 0;
    Future<void> worker() async {
      while (!stopped && next < missing.length) {
        final (p, i, t) = missing[next++];
        final h = await Dedupe.hashFor(t);
        _check(p, i, h);
        done++;
        if (mounted && (done % 8 == 0 || done == todo)) setState(() {});
      }
    }
    await Future.wait([for (var k = 0; k < 6; k++) worker()]);
    if (mounted) setState(() => scanning = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = hits.values.where((h) => !closeOnly || h.bits <= exactBits).toList()
      ..sort((a, b) => a.bits != b.bits ? a.bits.compareTo(b.bits) : b.post.created.compareTo(a.post.created));
    final exact = hits.values.where((h) => h.bits <= exactBits).length;
    return DecoratedBox(
      decoration: pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: const GlassBar(),
          title: const Text('Find this photo', style: TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            if (scanning) TextButton(onPressed: () => setState(() { stopped = true; scanning = false; }), child: const Text('Stop')),
          ],
        ),
        body: error != null
            ? Center(child: Text(error!))
            : Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 56, height: 56,
                        child: widget.picked != null
                            ? Image.memory(widget.picked!, fit: BoxFit.cover)
                            : Image.network(widget.fromItem!.thumb, fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.image)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(!loaded ? 'Looking…' : '${hits.length} match${hits.length == 1 ? '' : 'es'}, $exact exact', style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (scanning) Text('Checking pics $done of $todo', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                      ]),
                    ),
                    FilterChip(label: const Text('Exact only'), selected: closeOnly, onSelected: (v) => setState(() => closeOnly = v)),
                  ]),
                ),
                if (scanning) LinearProgressIndicator(value: todo == 0 ? null : done / todo),
                Expanded(
                  child: list.isEmpty
                      ? Center(child: Text(loaded && !scanning ? 'No matches in your saved posts' : 'Searching…', style: TextStyle(color: cs.onSurfaceVariant)))
                      : GridView.builder(
                          padding: EdgeInsets.fromLTRB(2, 2, 2, MediaQuery.paddingOf(context).bottom + 8),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
                          itemCount: list.length,
                          itemBuilder: (_, k) {
                            final h = list[k];
                            final m = h.post.media[h.index];
                            final ex = h.bits <= exactBits;
                            return GestureDetector(
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Viewer(entries: flatten([h.post]), start: h.index))),
                              onLongPress: () => showTileMenu(context, h.post, m, null),
                              child: Stack(fit: StackFit.expand, children: [
                                Image.network(m.thumb, fit: BoxFit.cover, cacheWidth: 360, errorBuilder: (_, _, _) => Container(color: cs.surfaceContainerHighest, child: const Icon(Icons.broken_image))),
                                Positioned(
                                  left: 4, top: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(color: ex ? cs.primary : Colors.black54, borderRadius: BorderRadius.circular(8)),
                                    child: Text(matchLabel(h.bits), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                                  ),
                                ),
                                Positioned(
                                  left: 0, right: 0, bottom: 0,
                                  child: GestureDetector(
                                    onTap: () => openAuthor(context, h.post.author),
                                    child: Container(
                                    color: Colors.black45,
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    child: Text('u/${h.post.author}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 10)),
                                  )),
                                ),
                              ]),
                            );
                          },
                        ),
                ),
              ]),
      ),
    );
  }
}

/// Offline search over every post saved on the phone (all feeds, subs, users and Deep Searches).
class CacheSearchScreen extends StatefulWidget {
  const CacheSearchScreen({super.key});
  @override
  State<CacheSearchScreen> createState() => _CacheSearchScreenState();
}

class _CacheSearchScreenState extends State<CacheSearchScreen> {
  static String _q = '';
  static MediaFilter? _kind;
  static final Set<PostStatus> _status = {};
  final c = TextEditingController(text: _q);
  List<Post>? all;
  List<Post> shown = [];
  Map<Object, int> counts = {};
  List<String> terms = [];
  Timer? _t;

  @override
  void initState() {
    super.initState();
    Db.loadEverything().then((a) {
      if (!mounted) return;
      all = a;
      _apply();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    c.dispose();
    super.dispose();
  }

  bool _kindOk(Post p, MediaFilter? k) => k == null || (k == MediaFilter.all ? p.media.isNotEmpty : kindMatches(p, k));

  void _apply() {
    final a = all;
    if (a == null || !mounted) return;
    terms = queryTerms(_q);
    final cnt = <Object, int>{};
    final out = <Post>[];
    for (final p in a) {
      if (!textMatches(p, terms)) continue;
      final st = statusOf(p);
      final sOk = _status.isEmpty || _status.contains(st);
      if (sOk) {
        cnt['any'] = (cnt['any'] ?? 0) + 1;
        for (final f in MediaFilter.values) {
          if (_kindOk(p, f)) cnt[f] = (cnt[f] ?? 0) + 1;
        }
      }
      if (_kindOk(p, _kind)) cnt[st] = (cnt[st] ?? 0) + 1;
      if (sOk && _kindOk(p, _kind)) out.add(p);
    }
    setState(() { shown = out; counts = cnt; });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    String n(Object k) => all == null ? '' : ' ${counts[k] ?? 0}';
    final any = _q.isNotEmpty || _kind != null || _status.isNotEmpty;
    return DecoratedBox(
      decoration: pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          flexibleSpace: const GlassBar(),
          titleSpacing: 0,
          title: SearchBox(
            controller: c,
            autofocus: _q.isEmpty,
            hint: 'Search everything saved',
            onChanged: (v) {
              setState(() {});
              _t?.cancel();
              _t = Timer(const Duration(milliseconds: 100), () { _q = v.trim(); _apply(); });
            },
            onClear: () { _t?.cancel(); c.clear(); _q = ''; _apply(); },
          ),
          actions: [
            IconButton(icon: const Icon(Icons.image_search), tooltip: 'Find this photo', onPressed: () => findPhotoFromPicker(context)),
            if (any)
              IconButton(icon: const Icon(Icons.filter_alt_off_outlined), tooltip: 'Clear all', onPressed: () {
                _t?.cancel();
                c.clear();
                _q = '';
                _kind = null;
                _status.clear();
                _apply();
              }),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(44),
            child: SizedBox(
              height: 44,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: Text('Everything${n('any')}'), showCheckmark: false, visualDensity: VisualDensity.compact, selected: _kind == null, onSelected: (_) { _kind = null; _apply(); }),
                ),
                for (final f in MediaFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      avatar: Icon(mediaFilterIcons[f], size: 16),
                      label: Text('${f == MediaFilter.all ? 'Media' : mediaFilterLabels[f]}${n(f)}'),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      selected: _kind == f,
                      onSelected: (_) { _kind = f; _apply(); },
                    ),
                  ),
                for (final st in PostStatus.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text('${statusLabels[st]}${n(st)}'),
                      visualDensity: VisualDensity.compact,
                      selected: _status.contains(st),
                      onSelected: (v) { v ? _status.add(st) : _status.remove(st); _apply(); },
                    ),
                  ),
              ]),
            ),
          ),
        ),
        body: all == null
            ? const Center(child: CircularProgressIndicator())
            : shown.isEmpty
                ? Center(child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(all!.isEmpty ? 'Nothing saved yet. Browse a bit first' : 'Nothing matches. Try fewer words', textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                  ))
                : ListView.builder(
                    padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 8),
                    itemCount: shown.length,
                    itemExtent: 84,
                    itemBuilder: (_, i) => _row(shown[i], cs),
                  ),
      ),
    );
  }

  Widget _row(Post p, ColorScheme cs) {
    final m = p.media.isNotEmpty ? p.media.first : null;
    final self = '${p.raw['selftext'] ?? ''}';
    final snip = _snippet(self.isNotEmpty ? self : linkUrl(p));
    final icon = isDocument(p) ? Icons.description_outlined : isLink(p) ? Icons.link : Icons.notes;
    return InkWell(
      onTap: () => openPost(context, p),
      onLongPress: () => showTileMenu(context, p, m, null),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 72, height: 72,
              child: m != null && m.thumb.isNotEmpty
                  ? Stack(fit: StackFit.expand, children: [
                      Image.network(m.thumb, fit: BoxFit.cover, cacheWidth: 180, errorBuilder: (_, _, _) => Container(color: cs.surfaceContainerHighest, child: const Icon(Icons.broken_image))),
                      if (m.type != MediaType.image) const Center(child: Icon(Icons.play_circle_fill, color: Colors.white, size: 24)),
                      if (p.media.length > 1) const Positioned(right: 2, top: 2, child: Icon(Icons.collections, color: Colors.white, size: 14)),
                    ])
                  : Container(color: cs.surfaceContainerHighest, child: Icon(icon)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
              HighlightText(p.title, terms: terms, maxLines: 2, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              if (snip.isNotEmpty) HighlightText(snip, terms: terms, maxLines: 1, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              GestureDetector(
                onTap: () => openAuthor(context, p.author),
                child: HighlightText('r/${p.subreddit} • u/${p.author} • ${p.date.toLocal().toString().substring(0, 10)}',
                    terms: terms, maxLines: 1, style: TextStyle(color: cs.primary, fontSize: 11)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  /// A line of body text around the first match.
  String _snippet(String s) {
    if (s.isEmpty) return '';
    final flat = s.replaceAll(RegExp(r'\s+'), ' ');
    final r = matchRanges(flat, terms);
    if (r.isEmpty) return flat.length > 120 ? flat.substring(0, 120) : flat;
    final a = (r.first.$1 - 30).clamp(0, flat.length);
    return '${a > 0 ? '…' : ''}${flat.substring(a, (a + 140).clamp(0, flat.length))}';
  }
}
