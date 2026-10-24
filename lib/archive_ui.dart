import 'package:flutter/material.dart';
import 'archive.dart';
import 'models.dart';

/// Image that, for archive posts, lazily checks availability (original → preview → Wayback) and shows a placeholder if gone.
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
  bool get _thumbMode => widget.thumb || widget.item.type != MediaType.image;
  String get _raw => _thumbMode ? widget.item.thumb : widget.item.full;

  @override
  void initState() {
    super.initState();
    if (widget.deep) _f = MediaCheck.resolve(widget.post, widget.item, thumb: _thumbMode);
  }

  @override
  Widget build(BuildContext context) {
    if (_f == null) return _img(_raw);
    return FutureBuilder<String?>(
      future: _f,
      builder: (ctx, s) {
        // While checking, show the image we already have instead of a spinner.
        if (s.connectionState != ConnectionState.done) return _img(_raw);
        // Only a positive "gone" verdict (404/410/removed placeholder, no preview/Wayback copy) shows the placeholder.
        return s.data == null ? const MediaGone() : _img(s.data!);
      },
    );
  }

  Widget _img(String u) => u.isEmpty
      ? _box(context, const Icon(Icons.movie))
      : FallbackImage(urls: [u, _raw, widget.item.thumb, ?widget.item.preview], fit: widget.fit, cacheWidth: widget.cacheWidth);

  Widget _box(BuildContext c, Widget child) => Container(color: Theme.of(c).colorScheme.surfaceContainerHighest, alignment: Alignment.center, child: child);
}

/// Network image that tries each URL in turn on load errors. A load error is never treated as "media gone":
/// it ends in a tap-to-retry icon. Once a frame has decoded it stays visible (gapless) even if a rebuild fails.
class FallbackImage extends StatefulWidget {
  final List<String> urls;
  final BoxFit fit;
  final int? cacheWidth;
  const FallbackImage({super.key, required this.urls, this.fit = BoxFit.cover, this.cacheWidth});
  @override
  State<FallbackImage> createState() => _FallbackImageState();
}

class _FallbackImageState extends State<FallbackImage> {
  int _i = 0;
  int _retry = 0;
  List<String> get _urls => widget.urls.where((u) => u.startsWith('http')).toSet().toList();

  @override
  void didUpdateWidget(FallbackImage old) {
    super.didUpdateWidget(old);
    if (old.urls.join() != widget.urls.join()) _i = 0;
  }

  @override
  Widget build(BuildContext context) {
    final us = _urls;
    final cs = Theme.of(context).colorScheme;
    if (_i >= us.length) {
      return GestureDetector(
        onTap: () => setState(() { _i = 0; _retry++; }),
        child: Container(color: cs.surfaceContainerHighest, alignment: Alignment.center, child: Icon(Icons.refresh, color: cs.onSurfaceVariant)),
      );
    }
    return Image.network(us[_i], key: ValueKey('${us[_i]}#$_retry'), fit: widget.fit, cacheWidth: widget.cacheWidth, gaplessPlayback: true,
        errorBuilder: (_, _, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() => _i++); });
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
        Text('media gone', style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
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
  final int bulkPages;
  final String oldest;
  final VoidCallback onRetry, onFetchAll, onCancel, onShowText;
  final String? error;
  const DeepStatusPanel({super.key, required this.all, required this.bulk, required this.done, required this.bulkPages, required this.oldest,
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
            ? 'Paging archives: $bulkPages page${bulkPages == 1 ? '' : 's'}$oldest'
            : all.isEmpty
                ? (done ? 'No archived posts found for this user' : 'No archived posts loaded yet')
                : media == 0
                    ? 'Found ${all.length} post${all.length == 1 ? '' : 's'}, all text, no media$oldest'
                    : '${all.length} archived posts · $media with media${text > 0 ? ' · $text text' : ''}$oldest';
        final errs = st.where((s) => !s.ok).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (bulk) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 2),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final s in st)
                    Row(children: [
                      Icon(s.ok ? Icons.check_circle_outline : Icons.error_outline, size: 14, color: s.ok ? Colors.green.shade600 : cs.error),
                      const SizedBox(width: 4),
                      Expanded(child: Text(
                        s.ok ? '${s.label}: ${s.count == 0 ? '0 posts found for this user' : '${s.count} posts on this page'}' : '${s.label}: ${s.error}',
                        style: small)),
                    ]),
                  const SizedBox(height: 2),
                  Text(summary, style: small.copyWith(fontWeight: FontWeight.w600)),
                ]),
              ),
              if (bulk)
                TextButton(onPressed: onCancel, child: const Text('Cancel'))
              else ...[
                if (errs.isNotEmpty || error != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
                if (!done && errs.isEmpty) TextButton(onPressed: onFetchAll, child: const Text('Fetch all')),
              ],
            ]),
          ),
          if (text > 0 && media == 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: onShowText, icon: const Icon(Icons.notes, size: 18), label: const Text('Show text posts'))),
            ),
          if (errs.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                title: Text('Error details', style: small),
                children: [
                  for (final s in errs)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: SelectableText('${s.label}: ${s.detail ?? s.error}', style: small.copyWith(fontFamily: 'monospace', fontSize: 11)),
                    ),
                ],
              ),
            ),
        ]);
      },
    );
  }
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
