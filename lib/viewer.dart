import 'package:flutter/material.dart';
import 'glass.dart';
import 'package:photo_view/photo_view.dart';
import 'package:url_launcher/url_launcher.dart';
import 'accounts.dart';
import 'archive.dart';
import 'archive_ui.dart';
import 'clean_image.dart';
import 'download.dart';
import 'filters.dart';
import 'models.dart';
import 'player.dart';
import 'source_bar.dart';
import 'sub_users.dart';

const viewerUserAgent = 'android:com.alok.hobee:v$appVersion (gallery app)';

class Entry {
  final Post post;
  final MediaItem item;
  final int index;
  Entry(this.post, this.item, this.index);
}

List<Entry> flatten(List<Post> posts) => [
      for (final p in posts)
        for (var i = 0; i < p.media.length; i++) Entry(p, p.media[i], i)
    ];

class Viewer extends StatefulWidget {
  final List<Entry> entries;
  final int start;
  const Viewer({super.key, required this.entries, required this.start});
  @override
  State<Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<Viewer> {
  late final PageController pc = PageController(initialPage: widget.start);
  late int cur = widget.start;
  bool chrome = true;

  @override
  void initState() {
    super.initState();
    markRead(widget.entries[widget.start].post.id);
    Interest.opened(widget.entries[widget.start].post);
  }

  Future<void> _download({bool all = false}) async {
    final e = widget.entries[cur];
    final items = all ? e.post.media : [e.item];
    final m = ScaffoldMessenger.of(context);
    m.showSnackBar(SnackBar(content: Text('Downloading ${items.length} item(s)…')));
    var ok = 0;
    for (final it in items) {
      try {
        await Downloader.save(it, 'hobee_${e.post.id}');
        ok++;
        if (ok == 1) Interest.downloaded(e.post);
      } catch (err) {
        m.showSnackBar(SnackBar(content: Text('Failed: $err')));
      }
    }
    m.showSnackBar(SnackBar(content: Text('Saved $ok/${items.length} to Pictures')));
  }

  Widget _photo(String url, MediaItem it) =>
      PhotoFallback(key: ValueKey('${it.url}|${it.thumb}'), urls: [url, it.full, it.url, ?it.preview, it.thumb]);

  @override
  Widget build(BuildContext context) {
    final e = widget.entries[cur];
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: chrome
          ? AppBar(
              backgroundColor: Colors.transparent,
              flexibleSpace: Glass(fill: Colors.black.withValues(alpha: 0.35), border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.15))), child: const SizedBox.expand()),
              foregroundColor: Colors.white,
              title: Text(e.post.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
              actions: [
                if (e.item.type == MediaType.image)
                IconButton(icon: const Icon(Icons.download), tooltip: 'Download', onPressed: () => _download()),
                if (e.post.media.length > 1)
                  IconButton(icon: const Icon(Icons.download_for_offline), tooltip: 'Download all', onPressed: () => _download(all: true)),
                IconButton(
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () => launchUrl(Uri.parse('https://www.reddit.com${e.post.permalink}'), mode: LaunchMode.externalApplication)),
              ],
            )
          : null,
      body: GestureDetector(
        onTap: () => setState(() => chrome = !chrome),
        child: Stack(children: [
          PageView.builder(
            controller: pc,
            itemCount: widget.entries.length,
            onPageChanged: (i) { markRead(widget.entries[i].post.id); if (widget.entries[i].post.id != widget.entries[cur].post.id) Interest.opened(widget.entries[i].post); setState(() => cur = i); },
            itemBuilder: (_, i) {
              final it = widget.entries[i].item;
              if (it.type == MediaType.video) return VideoPage(item: it, active: i == cur);
              if (isDeep(currentSource.value)) {
                return FutureBuilder<String?>(
                  future: MediaCheck.resolve(widget.entries[i].post, it),
                  builder: (_, s) => s.connectionState != ConnectionState.done
                      ? _photo(it.full, it)
                      : s.data == null
                          ? const MediaGone()
                          : _photo(s.data!, it),
                );
              }
              return _photo(it.full, it);
            },
          ),

          if (chrome)
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: Glass(
                fill: Colors.black.withValues(alpha: 0.35),
                border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.15))),
                child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  AuthorChip(e.post.author),
                  const SizedBox(height: 6),
                  Text('r/${e.post.subreddit} • ${e.post.date.toLocal().toString().substring(0, 10)}'
                      '${e.post.media.length > 1 ? '  •  ${e.index + 1}/${e.post.media.length}' : ''}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ]),
              )),
            ),
        ]),
      ),
    );
  }
}

/// Viewer photo: tries each URL in order (original, preview, thumbnail) and shows the first that loads.
///
/// 1.3.5 bug: PhotoView's errorBuilder runs on every rebuild of a failed page, and each run scheduled
/// another "next URL" step. One failure could skip several candidates (including the working preview),
/// so the chain ran out and only the retry icon was left. Now a failure only advances when it belongs
/// to the URL currently shown, decodes are capped to screen size, and retry evicts the image cache.
class PhotoFallback extends StatefulWidget {
  final List<String> urls;
  /// Test seam: builds the provider for a URL.
  final ImageProvider Function(String url, int maxPx)? providerFor;
  const PhotoFallback({super.key, required this.urls, this.providerFor});
  @override
  State<PhotoFallback> createState() => PhotoFallbackState();
}

class PhotoFallbackState extends State<PhotoFallback> {
  int i = 0;
  final failures = <String>[]; // "url → reason", newest last
  int _gen = 0; // bumps on retry so a fresh provider/key is used

  List<String> get urls => widget.urls.where((u) => u.startsWith('http')).toSet().toList();

  @override
  void didUpdateWidget(PhotoFallback oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The URL list changed (e.g. the media check resolved): start again from the best URL.
    if (oldWidget.urls.join('|') != widget.urls.join('|')) i = 0;
  }

  ImageProvider _provider(String u, int maxPx) {
    if (widget.providerFor != null) return widget.providerFor!(u, maxPx);
    // Reddit JPEGs: clean up the compression first (blocks, bleeding reds). Same size cap as below.
    if (cleanJpegs.value) return CleanNetworkImage(u, maxPx, headers: const {'User-Agent': viewerUserAgent});
    // Cap decode size: some originals are 4000-9000 px wide and fail to decode on phones.
    return ResizeImage(NetworkImage(u, headers: const {'User-Agent': viewerUserAgent}), width: maxPx, policy: ResizeImagePolicy.fit, allowUpscaling: false);
  }

  void _failed(String u, Object err) {
    final us = urls;
    if (!mounted || i >= us.length || us[i] != u) return; // stale or repeated report for an older URL
    setState(() {
      failures.add('$u → ${_reason(err)}');
      i++;
    });
  }

  static String _reason(Object e) {
    final s = '$e';
    final m = RegExp(r'statusCode: (\d+)').firstMatch(s);
    if (m != null) return 'HTTP ${m.group(1)}';
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  void retry() {
    for (final u in urls) {
      PaintingBinding.instance.imageCache.evict(NetworkImage(u, headers: const {'User-Agent': viewerUserAgent}));
      PaintingBinding.instance.imageCache.clear();
    }
    PaintingBinding.instance.imageCache.clearLiveImages();
    setState(() {
      i = 0;
      failures.clear();
      _gen++;
    });
  }

  void _showDebug() {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            failures.isEmpty ? 'No load errors. Showing:\n${i < urls.length ? urls[i] : '-'}' : 'Load errors:\n${failures.join('\n')}',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final us = urls;
    if (i >= us.length) {
      final removed = failures.isNotEmpty && failures.every((f) => f.endsWith('HTTP 404') || f.endsWith('HTTP 410'));
      return GestureDetector(
        onLongPress: _showDebug,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: const Icon(Icons.refresh, color: Colors.white70), tooltip: 'Retry', onPressed: retry),
            const SizedBox(height: 4),
            Text(us.isEmpty ? 'No image URL for this post' : removed ? 'Removed' : 'Couldn\'t load image (${failures.isNotEmpty ? failures.last.split(' → ').last : 'error'})',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const Text('Long-press for details', style: TextStyle(color: Colors.white30, fontSize: 11)),
          ]),
        ),
      );
    }
    final u = us[i];
    final mq = MediaQuery.of(context);
    final maxPx = ((mq.size.longestSide * mq.devicePixelRatio) * 1.5).clamp(1024, 4096).round();
    return GestureDetector(
      onLongPress: _showDebug,
      child: PhotoView(
        key: ValueKey('$u#$_gen'),
        imageProvider: _provider(u, maxPx),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (_, _) => const Center(child: CircularProgressIndicator()),
        errorBuilder: (_, err, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _failed(u, err));
          return const Center(child: CircularProgressIndicator());
        },
      ),
    );
  }
}
