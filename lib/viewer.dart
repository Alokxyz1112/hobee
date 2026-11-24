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

const viewerUserAgent = 'android:io.github.cscott0108.hobees:v$appVersion (gallery app)';

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
  final _panelKey = GlobalKey();

  /// Tell the video player how tall the bottom info panel is, so its controls sit above it.
  void _reportPanel() {
    final h = chrome ? (_panelKey.currentContext?.size?.height ?? 0.0) : 0.0;
    if (viewerChromeInset.value != h) viewerChromeInset.value = h;
  }

  @override
  void dispose() {
    viewerZoomed.removeListener(_zoomChanged);
    viewerChromeInset.value = 0;
    viewerZoomed.value = false;
    super.dispose();
  }

  void _zoomChanged() {
    // Zoomed in: hide the panels so the picture isn't re-blurred behind them on every frame; for videos also
    // stop the page swipe (pictures hand the swipe back to the pager at their edges themselves).
    if (viewerZoomed.value && chrome) chrome = false;
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    viewerZoomed.value = false;
    viewerZoomed.addListener(_zoomChanged);
    markRead(widget.entries[widget.start].post.id);
    Interest.opened(widget.entries[widget.start].post);
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefetch(widget.start));
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

  Widget _photo(String url, MediaItem it) => PhotoFallback(
      key: ValueKey('${it.url}|${it.thumb}'),
      urls: [url, it.full, it.url, ?it.preview, it.thumb],
      placeholder: it.thumb.startsWith('http') ? gridThumbProvider(it.thumb) : null);

  /// Start decoding the next images' originals so swiping to them is instant. Same provider and size cap as
  /// the viewer, so the decoded image is reused from the cache. Errors are ignored here; the page retries.
  void _prefetch(int from) {
    if (!mounted) return;
    final maxPx = viewerMaxPx(context);
    final deep = isDeep(currentSource.value);
    for (final k in prefetchTargets(widget.entries, from)) {
      final e = widget.entries[k];
      final url = deep ? MediaCheck.resolve(e.post, e.item) : Future<String?>.value(e.item.full);
      url.then((u) {
        if (mounted && u != null && u.startsWith('http')) precacheImage(viewerProvider(u, maxPx), context, onError: (_, _) {});
      }, onError: (_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entries[cur];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportPanel();
    });
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
                    tooltip: 'Open in browser', icon: const Icon(Icons.open_in_new),
                    onPressed: () => launchUrl(Uri.parse('https://www.reddit.com${e.post.permalink}'), mode: LaunchMode.externalApplication)),
              ],
            )
          : null,
      body: GestureDetector(
        onTap: () => setState(() => chrome = !chrome),
        child: Stack(children: [
          // The scope lets a zoomed picture pan to its edge before the pager takes the swipe, instead of
          // both fighting over every move (the sluggish zoom).
          PhotoViewGestureDetectorScope(
           axis: Axis.horizontal,
           child: PageView.builder(
            controller: pc,
            physics: viewerZoomed.value && e.item.type == MediaType.video ? const NeverScrollableScrollPhysics() : null,
            itemCount: widget.entries.length,
            onPageChanged: (i) { viewerZoomed.value = false; markRead(widget.entries[i].post.id); if (widget.entries[i].post.id != widget.entries[cur].post.id) Interest.opened(widget.entries[i].post); setState(() => cur = i); _prefetch(i); },
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
          ),

          if (chrome)
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: Glass(
                key: _panelKey,
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

/// Decode cap for viewer images: some originals are 4000-9000 px wide and fail to decode on phones.
int viewerMaxPx(BuildContext context) {
  final mq = MediaQuery.of(context);
  return ((mq.size.longestSide * mq.devicePixelRatio) * 1.5).clamp(1024, 4096).round();
}

/// Provider the viewer uses for a full-size URL. Prefetch must use the same one so the cache is hit.
ImageProvider viewerProvider(String u, int maxPx) {
  // Reddit JPEGs: clean up the compression first (blocks, bleeding reds). Same size cap as below.
  if (cleanJpegs.value) return CleanNetworkImage(u, maxPx, headers: const {'User-Agent': viewerUserAgent});
  return ResizeImage(NetworkImage(u, headers: const {'User-Agent': viewerUserAgent}), width: maxPx, policy: ResizeImagePolicy.fit, allowUpscaling: false);
}

/// The grid tile's provider for [thumb] (same as Image.network(thumb, cacheWidth: 360)), so the viewer gets a cache hit.
ImageProvider gridThumbProvider(String thumb) => ResizeImage(NetworkImage(thumb), width: 360);

/// Entries worth prefetching after [cur]: the next [ahead] positions, images only.
List<int> prefetchTargets(List<Entry> entries, int cur, {int ahead = 2}) => [
      for (var k = cur + 1; k < entries.length && k <= cur + ahead; k++)
        if (entries[k].item.type == MediaType.image) k
    ];

/// Viewer photo: shows [placeholder] (the cached grid thumbnail) at once, then tries each full-size URL in
/// order (original, preview, thumbnail) and fades in the first that loads.
///
/// 1.3.5 bug: PhotoView's errorBuilder runs on every rebuild of a failed page, and each run scheduled
/// another "next URL" step. One failure could skip several candidates (including the working preview),
/// so the chain ran out and only the retry icon was left. Now each URL has one stream listener and a failure
/// only advances when it belongs to the URL currently shown, decodes are capped to screen size, and retry evicts the image cache.
class PhotoFallback extends StatefulWidget {
  final List<String> urls;
  /// Shown at once (usually the cached grid thumbnail) until a full-size URL has decoded.
  final ImageProvider? placeholder;
  /// Test seam: builds the provider for a URL.
  final ImageProvider Function(String url, int maxPx)? providerFor;
  const PhotoFallback({super.key, required this.urls, this.placeholder, this.providerFor});
  @override
  State<PhotoFallback> createState() => PhotoFallbackState();
}

class PhotoFallbackState extends State<PhotoFallback> {
  int i = 0;
  final failures = <String>[]; // "url → reason", newest last
  int _gen = 0; // bumps on retry so a fresh provider/key is used
  /// True once the current full-size URL has decoded.
  bool loaded = false;
  String? _watchKey;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  List<String> get urls => withRedditOriginals(widget.urls);

  @override
  void didUpdateWidget(PhotoFallback oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The URL list changed (e.g. the media check resolved): start again from the best URL.
    if (oldWidget.urls.join('|') != widget.urls.join('|')) i = 0;
  }

  @override
  void dispose() {
    _unwatch();
    super.dispose();
  }

  void _unwatch() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
    _watchKey = null;
  }

  /// Follows the current URL's load: marks [loaded] on the first frame, advances the chain on error.
  /// One listener per URL, so rebuilds can't report the same failure twice (the 1.3.5 bug).
  void _watch(ImageProvider p, String u, String key) {
    if (_watchKey == key) return;
    _unwatch();
    _watchKey = key;
    loaded = false;
    final s = p.resolve(createLocalImageConfiguration(context));
    final l = ImageStreamListener((_, sync) {
      if (!mounted || _watchKey != key || loaded) return;
      if (sync) {
        loaded = true; // already decoded (prefetched): show it in this build
      } else {
        setState(() => loaded = true);
      }
    }, onError: (err, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_watchKey == key) _failed(u, err);
      });
    });
    _stream = s;
    _listener = l;
    s.addListener(l);
  }

  ImageProvider _provider(String u, int maxPx) => widget.providerFor?.call(u, maxPx) ?? viewerProvider(u, maxPx);

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
    _unwatch();
    setState(() {
      i = 0;
      failures.clear();
      _gen++;
      loaded = false;
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

  Widget _errorView(List<String> us) {
    final removed = failures.isNotEmpty && failures.every((f) => f.endsWith('HTTP 404') || f.endsWith('HTTP 410'));
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        IconButton(icon: const Icon(Icons.refresh, color: Colors.white70), tooltip: 'Retry', onPressed: retry),
        const SizedBox(height: 4),
        Text(us.isEmpty ? 'No image URL for this post' : removed ? 'Removed' : 'Couldn\'t load image (${failures.isNotEmpty ? failures.last.split(' → ').last : 'error'})',
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const Text('Long-press for details', style: TextStyle(color: Colors.white30, fontSize: 11)),
      ]),
    );
  }

  Widget _placeholder({Widget Function()? onError}) => Image(
        image: widget.placeholder!,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => onError?.call() ?? const SizedBox.shrink(),
      );

  @override
  Widget build(BuildContext context) {
    final us = urls;
    final ph = widget.placeholder;
    if (i >= us.length) {
      _unwatch();
      // Every full-size URL failed. With a thumbnail, stay on it quietly (small retry in the corner);
      // only show the error state when even that can't load.
      return GestureDetector(
        onLongPress: _showDebug,
        child: ph == null
            ? _errorView(us)
            : Stack(fit: StackFit.expand, children: [
                _placeholder(onError: () => _errorView(us)),
                Positioned(
                  right: 8,
                  bottom: 120,
                  child: IconButton(
                    key: const Key('quiet-retry'),
                    icon: const Icon(Icons.refresh, color: Colors.white54, size: 20),
                    tooltip: 'Retry full quality',
                    onPressed: retry,
                  ),
                ),
              ]),
      );
    }
    final u = us[i];
    final maxPx = viewerMaxPx(context);
    final p = _provider(u, maxPx);
    _watch(p, u, '$u#$_gen#$maxPx');
    return GestureDetector(
      onLongPress: _showDebug,
      child: Stack(fit: StackFit.expand, children: [
        // The thumbnail stays underneath; the full image fades in over it.
        if (ph != null) _placeholder(),
        AnimatedOpacity(
          key: const Key('full-fade'),
          opacity: loaded ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: PhotoView(
            key: ValueKey('$u#$_gen'),
            imageProvider: p,
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 4,
            scaleStateChangedCallback: (s) => viewerZoomed.value = s != PhotoViewScaleState.initial,
            backgroundDecoration: const BoxDecoration(color: Colors.black),
            loadingBuilder: (_, _) => const SizedBox.shrink(),
            errorBuilder: (_, _, _) => const SizedBox.shrink(), // failures are handled by _watch
          ),
        ),
        if (!loaded)
          ph == null
              ? const Center(child: CircularProgressIndicator())
              : const Align(alignment: Alignment.bottomCenter, child: LinearProgressIndicator(minHeight: 2)),
      ]),
    );
  }
}
