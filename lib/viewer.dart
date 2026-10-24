import 'package:flutter/material.dart';
import 'glass.dart';
import 'package:photo_view/photo_view.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'archive.dart';
import 'archive_ui.dart';
import 'download.dart';
import 'filters.dart';
import 'models.dart';
import 'source_bar.dart';

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
      } catch (err) {
        m.showSnackBar(SnackBar(content: Text('Failed: $err')));
      }
    }
    m.showSnackBar(SnackBar(content: Text('Saved $ok/${items.length} to Hobee folder')));
  }

  Widget _photo(String url, MediaItem it) => _PhotoFallback(urls: [url, it.full, it.url, ?it.preview, it.thumb]);

  Widget _photoOne(String url, VoidCallback onError) => PhotoView(
        key: ValueKey(url),
        imageProvider: NetworkImage(url),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (_, _) => const Center(child: CircularProgressIndicator()),
        errorBuilder: (_, _, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) => onError());
          return const Center(child: CircularProgressIndicator());
        },
      );

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
            onPageChanged: (i) { markRead(widget.entries[i].post.id); setState(() => cur = i); },
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
                child: Text(
                  'r/${e.post.subreddit} • u/${e.post.author} • ${e.post.date.toLocal().toString().substring(0, 10)}'
                  '${e.post.media.length > 1 ? '  •  ${e.index + 1}/${e.post.media.length}' : ''}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              )),
            ),
        ]),
      ),
    );
  }
}

class VideoPage extends StatefulWidget {
  final MediaItem item;
  final bool active;
  const VideoPage({super.key, required this.item, required this.active});
  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  VideoPlayerController? c;
  String? err;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final hls = widget.item.hls;
    // HLS playlist includes the audio track; fallback mp4 is video-only for reddit videos.
    final ctrl = hls != null
        ? VideoPlayerController.networkUrl(Uri.parse(hls), formatHint: VideoFormat.hls)
        : VideoPlayerController.networkUrl(Uri.parse(widget.item.url));
    try {
      await ctrl.initialize();
      await ctrl.setLooping(true);
      if (widget.active) await ctrl.play();
      if (mounted) {
        setState(() => c = ctrl);
      } else {
        ctrl.dispose();
      }
    } catch (e) {
      if (mounted) setState(() => err = '$e');
    }
  }

  @override
  void didUpdateWidget(VideoPage old) {
    super.didUpdateWidget(old);
    if (c == null) return;
    widget.active ? c!.play() : c!.pause();
  }

  @override
  void dispose() {
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (err != null) return Center(child: Text('Video error\n$err', style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center));
    final v = c;
    if (v == null) return const Center(child: CircularProgressIndicator());
    return Stack(alignment: Alignment.center, children: [
      InteractiveViewer(maxScale: 4, child: Center(child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)))),
      Positioned(
        bottom: 60, left: 8, right: 8,
        child: Row(children: [
          ValueListenableBuilder(
            valueListenable: v,
            builder: (_, val, _) => IconButton(
              color: Colors.white,
              icon: Icon(val.isPlaying ? Icons.pause : Icons.play_arrow),
              onPressed: () => val.isPlaying ? v.pause() : v.play(),
            ),
          ),
          Expanded(child: VideoProgressIndicator(v, allowScrubbing: true, colors: const VideoProgressColors(playedColor: Color(0xFFE53935)))),
          ValueListenableBuilder(
            valueListenable: v,
            builder: (_, val, _) => IconButton(
              color: Colors.white,
              icon: Icon(val.volume == 0 ? Icons.volume_off : Icons.volume_up),
              onPressed: () => v.setVolume(val.volume == 0 ? 1 : 0),
            ),
          ),
        ]),
      ),
    ]);
  }
}

/// Viewer photo: original first, then preview/thumbnail on load error. Never shows "media gone" for a load error.
class _PhotoFallback extends StatefulWidget {
  final List<String> urls;
  const _PhotoFallback({required this.urls});
  @override
  State<_PhotoFallback> createState() => _PhotoFallbackState();
}

class _PhotoFallbackState extends State<_PhotoFallback> {
  int _i = 0;
  @override
  Widget build(BuildContext context) {
    final us = widget.urls.where((u) => u.startsWith('http')).toSet().toList();
    if (_i >= us.length) {
      return Center(child: IconButton(icon: const Icon(Icons.refresh, color: Colors.white70), onPressed: () => setState(() => _i = 0)));
    }
    final st = context.findAncestorStateOfType<_ViewerState>();
    return st!._photoOne(us[_i], () { if (mounted) setState(() => _i++); });
  }
}
