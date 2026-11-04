import 'error_text.dart';
import 'clean_image.dart' show withRedditOriginals;
import 'package:flutter/material.dart';
import 'archive.dart';
import 'models.dart';

/// Image that, for archive posts, lazily checks availability (original -> preview -> thumbnail -> Wayback) and shows
/// an 'Image gone' state when nothing reachable is left. Tap that state to check again.
class ArchiveImage extends StatefulWidget {
  final Post post;
  final MediaItem item;
  final bool thumb;
  final BoxFit fit;
  final int? cacheWidth;
  final bool deep;
  const ArchiveImage({super.key, required this.post, required this.item, this.thumb = true, this.fit = BoxFit.cover, this.cacheWidth, required this.deep});
  @override
  State<ArchiveImage> createState() => _ArchiveImageState();
}

class _ArchiveImageState extends State<ArchiveImage> {
  Future<String?>? _f;
  bool _disposed = false;
  bool get _thumbMode => widget.thumb || widget.item.type != MediaType.image;
  String get _raw => _thumbMode ? widget.item.thumb : widget.item.full;

  @override
  void initState() {
    super.initState();
    if (widget.deep && _raw.isEmpty && widget.item.thumb.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // Only when the URLs we already have fail do we ask MediaCheck (originals, previews, Wayback). Probing every tile
  // up front meant hundreds of queued checks after a long scroll, and new tiles waited behind them.
  void _check() {
    if (_disposed || _f != null) return;
    final f = MediaCheck.resolve(widget.post, widget.item, thumb: _thumbMode, wanted: () => !_disposed && mounted);
    setState(() { _f = f; });
  }

  Future<void> _recheck() async {
    await MediaCheck.forget(widget.post, widget.item, thumb: _thumbMode);
    if (!mounted) return;
    setState(() { _f = null; });
    _check();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.deep) return _img(_raw);
    if (_f == null) {
      return _raw.isEmpty && widget.item.thumb.isEmpty
          ? _box(context, null)
          : FallbackImage(urls: [_raw, widget.item.thumb], fit: widget.fit, cacheWidth: widget.cacheWidth, onExhausted: _check);
    }
    return FutureBuilder<String?>(
      future: _f,
      builder: (ctx, s) {
        if (s.hasError) return GestureDetector(onTap: _recheck, child: _box(context, const Icon(Icons.refresh)));
        if (s.connectionState != ConnectionState.done) return _box(context, null);
        if (s.data == null) WidgetsBinding.instance.addPostFrameCallback((_) => MediaCheck.markGone(widget.post.id));
        return s.data == null ? GestureDetector(onTap: _recheck, child: const MediaGone()) : _img(s.data!);
      },
    );
  }

  Widget _img(String u) => u.isEmpty
      ? _box(context, const Icon(Icons.movie))
      : FallbackImage(urls: [u, _raw, widget.item.thumb, ?widget.item.preview], fit: widget.fit, cacheWidth: widget.cacheWidth,
          onAllGone: () => MediaCheck.markGone(widget.post.id));

  Widget _box(BuildContext c, Widget? child) => Container(color: Theme.of(c).colorScheme.surfaceContainerHighest, alignment: Alignment.center, child: child);
}

/// Network image that tries each URL in turn. If every URL answered 404/410 it shows 'Image gone'; other errors
/// (offline, 429, 5xx) retry on their own with backoff, then leave a tap-to-retry icon that really reloads.
class FallbackImage extends StatefulWidget {
  final List<String> urls;
  final BoxFit fit;
  final int? cacheWidth;
  final VoidCallback? onAllGone;
  /// If set, called once every URL has failed (for any reason) instead of showing the retry / gone state.
  final VoidCallback? onExhausted;
  const FallbackImage({super.key, required this.urls, this.fit = BoxFit.cover, this.cacheWidth, this.onAllGone, this.onExhausted});
  @override
  State<FallbackImage> createState() => _FallbackImageState();
}

const imageHeaders = {'User-Agent': 'android:com.alok.hobee:v$appVersion (gallery app)'};
const _autoRetries = 2;

class _FallbackImageState extends State<FallbackImage> {
  int _i = 0;
  int _retry = 0;
  bool _soft = false; // saw an error that wasn't a clear 404/410
  List<String> get _urls => withRedditOriginals(widget.urls);

  @override
  void didUpdateWidget(FallbackImage old) {
    super.didUpdateWidget(old);
    if (old.urls.join() != widget.urls.join()) { _i = 0; _soft = false; }
  }

  void _again() {
    for (final u in _urls) {
      final n = NetworkImage(u, headers: imageHeaders);
      PaintingBinding.instance.imageCache.evict(n);
      PaintingBinding.instance.imageCache.evict(ResizeImage.resizeIfNeeded(widget.cacheWidth, null, n));
    }
    setState(() { _i = 0; _retry++; _soft = false; });
  }

  final Set<String> _handled = {};
  void _failed(String url, Object err) {
    if (!_handled.add('$url#$_retry') || _i >= _urls.length || _urls[_i] != url) return;
    final code = err is NetworkImageLoadException ? err.statusCode : 0;
    if (code != 404 && code != 410 && code != 403) _soft = true;
    _i++;
    if (_i >= _urls.length && widget.onExhausted != null) {
      widget.onExhausted!();
      return;
    }
    if (_i >= _urls.length) {
      if (_soft && _retry < _autoRetries) {
        Future.delayed(Duration(seconds: 2 << _retry), () { if (mounted && _i >= _urls.length) _again(); });
      } else {
        // Deleted, or still broken after retries: a dead tile is just an empty box, so let the grid drop it.
        widget.onAllGone?.call();
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final us = _urls;
    final cs = Theme.of(context).colorScheme;
    if (_i >= us.length) {
      return GestureDetector(
        onTap: _again,
        child: _soft
            ? Container(color: cs.surfaceContainerHighest, alignment: Alignment.center, child: Icon(Icons.refresh, color: cs.onSurfaceVariant))
            : const MediaGone(),
      );
    }
    final cur = us[_i];
    return Image(
        image: ResizeImage.resizeIfNeeded(widget.cacheWidth, null, NetworkImage(us[_i], headers: imageHeaders)),
        key: ValueKey('${us[_i]}#$_retry'), fit: widget.fit, gaplessPlayback: true,
        frameBuilder: (_, child, frame, sync) => frame == null && !sync ? Container(color: cs.surfaceContainerHighest) : child,
        errorBuilder: (_, err, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _failed(cur, err); });
          return Container(color: cs.surfaceContainerHighest);
        });
  }
}

class MediaGone extends StatelessWidget {
  const MediaGone({super.key});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.image_not_supported_outlined, color: cs.onSurfaceVariant),
        Text('Removed', style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
      ]),
    );
  }
}

/// Live / Removed / Archive badge for deep-profile posts.
class StatusBadge extends StatelessWidget {
  final Post post;
  const StatusBadge(this.post, {super.key});
  @override
  Widget build(BuildContext context) {
    final (label, color) = isLive(post)
        ? ('Live', Colors.green.shade700)
        : isRemoved(post)
            ? ('Removed', Colors.red.shade700)
            : ('Archive', Colors.blueGrey.shade700);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
    );
  }
}

/// Deep Search status: per-archive result, post counts (media vs text), retry and raw error detail.
class DeepStatusPanel extends StatelessWidget {
  final List<Post> all;
  final bool bulk, done;
  final int bulkPages, bulkAdded;
  final String oldest;
  final VoidCallback onRetry, onFetchAll, onCancel, onShowText;
  final String? error;
  const DeepStatusPanel({super.key, required this.all, required this.bulk, required this.done, required this.bulkPages, this.bulkAdded = 0, required this.oldest,
      required this.onRetry, required this.onFetchAll, required this.onCancel, required this.onShowText, this.error});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final small = TextStyle(color: cs.onSurfaceVariant, fontSize: 12);
    return ValueListenableBuilder(
      valueListenable: archiveStatus,
      builder: (_, st, _) {
        final media = all.where((p) => p.media.isNotEmpty).length;
        final text = all.length - media;
        final summary = bulk
            ? 'Loading all: ${all.length} posts, $bulkPages page${bulkPages == 1 ? '' : 's'}${bulkAdded > 0 ? ' (+$bulkAdded)' : ''}$oldest'
            : all.isEmpty
                ? (done ? 'No archived posts found for this user' : 'No archived posts loaded yet')
                : media == 0
                    ? 'Found ${all.length} post${all.length == 1 ? '' : 's'}, all text, no media$oldest'
                    : '${all.length} archived posts · $media with media${text > 0 ? ' · $text text' : ''}$oldest';
        final errs = st.where((s) => !s.ok).toList();
        final anyPosts = all.isNotEmpty || st.any((s) => (s.count ?? 0) > 0);
        final working = st.where((s) => s.ok && (s.count ?? 0) > 0).length;
        final sourcesTitle = st.isEmpty ? '' : sourcesSummary(st, anyPosts);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (bulk) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
            child: Row(children: [
              Expanded(child: Text(summary, style: small.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface))),
              if (bulk)
                TextButton(key: const Key('load-all-stop'), onPressed: onCancel, child: const Text('Stop'))
              else ...[
                if ((errs.isNotEmpty && working == 0) || error != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
                if (!done && all.isNotEmpty && (errs.isEmpty || working > 0)) TextButton(key: const Key('load-all'), onPressed: onFetchAll, child: const Text('Load all')),
              ],
            ]),
          ),
          if (text > 0 && media == 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: onShowText, icon: const Icon(Icons.notes, size: 18), label: const Text('Show text posts'))),
            ),
          if (st.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                title: Text(sourcesTitle, style: small),
                children: [
                  for (final s in st)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(children: [
                        Icon(_icon(s, anyPosts), size: 14, color: _color(s, anyPosts, cs)),
                        const SizedBox(width: 6),
                        Expanded(child: Text(sourceLine(s, anyPosts), style: small)),
                      ]),
                    ),
                  if (errs.isNotEmpty)
                    ExpansionTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      tilePadding: EdgeInsets.zero,
                      title: Text('Technical details', style: small.copyWith(fontSize: 11)),
                      children: [
                        for (final s in errs)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: SelectableText(detailLine(s.label, s.detail ?? s.error ?? ''), style: small.copyWith(fontFamily: 'monospace', fontSize: 11)),
                          ),
                      ],
                    ),
                ],
              ),
            ),
        ]);
      },
    );
  }

  static IconData _icon(ProviderStatus s, bool anyPosts) {
    if (!s.ok) return Icons.remove_circle_outline;
    if ((s.count ?? 0) > 0) return Icons.check_circle_outline;
    return anyPosts ? Icons.help_outline : Icons.radio_button_unchecked;
  }

  static Color _color(ProviderStatus s, bool anyPosts, ColorScheme cs) {
    if (s.ok && (s.count ?? 0) > 0) return Colors.green.shade600;
    if (s.ok && anyPosts) return Colors.orange.shade700;
    return cs.outline;
  }
}

/// Friendly one-line reason for a source that did not answer.
String friendlyError(String? e) {
  final t = (e ?? '').toLowerCase();
  if (t.contains('429') || t.contains('rate')) return 'busy right now, will work later';
  if (t.contains('403') || t.contains('blocked')) return 'blocked from this network';
  if (t.contains('timed out') || t.contains('timeout')) return 'too slow to answer';
  if (t.contains('network')) return 'could not connect';
  if (t.contains('404')) return 'not found';
  return 'not available right now';
}

/// One status row, e.g. 'Arctic Shift: 8 posts in the last batch'.
String sourceLine(ProviderStatus s, bool anyPosts) {
  if (!s.ok) return '${s.label}: ${friendlyError(s.error)}';
  final n = s.count ?? 0;
  if (n == 0) return anyPosts ? '${s.label}: returned nothing (may hide this user)' : '${s.label}: no posts found';
  return '${s.label}: $n post${n == 1 ? '' : 's'} in the last batch';
}

/// Collapsed title of the source list, e.g. 'Sources: 1 working, 3 unavailable'.
String sourcesSummary(List<ProviderStatus> st, bool anyPosts) {
  final good = st.where((s) => s.ok && (s.count ?? 0) > 0).length;
  final empty = st.where((s) => s.ok && (s.count ?? 0) == 0).length;
  final bad = st.where((s) => !s.ok).length;
  final parts = [
    if (good > 0) '$good working',
    if (empty > 0) '$empty empty',
    if (bad > 0) '$bad unavailable',
  ];
  return 'Sources: ${parts.join(', ')}';
}

/// Small "x3" badge for collapsed duplicates.
class DupBadge extends StatelessWidget {
  final int n;
  const DupBadge(this.n, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: const Color(0xFFE53935).withValues(alpha: 0.9), borderRadius: BorderRadius.circular(6)),
        child: Text('×$n', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
      );
}

/// Bottom sheet listing all copies of a duplicate group.
Future<void> showCopiesSheet(BuildContext context, List<Post> copies, void Function(Post) onOpen) => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).canvasColor.withValues(alpha: 0.92),
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('${copies.length} copies of this post', style: Theme.of(ctx).textTheme.titleMedium)),
          for (final p in copies)
            ListTile(
              dense: true,
              title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('r/${p.subreddit} · ${p.date.toLocal().toString().substring(0, 16)}'),
              trailing: p.raw['_hobee_src'] != null ? StatusBadge(p) : null,
              onTap: () {
                Navigator.pop(ctx);
                onOpen(p);
              },
            ),
        ]),
      ),
    );
