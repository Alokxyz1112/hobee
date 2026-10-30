import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'embeds.dart';
import 'models.dart';

/// Player settings, saved.
class VideoPrefs {
  static final startMuted = ValueNotifier<bool>(false);
  static final muted = ValueNotifier<bool>(false);
  static final loop = ValueNotifier<bool>(true);
  static final speed = ValueNotifier<double>(1);
  static final _pos = <String, int>{};
  static SharedPreferences? _sp;

  static Future<void> load() async {
    final sp = _sp = await SharedPreferences.getInstance();
    startMuted.value = sp.getBool('startMuted') ?? false;
    muted.value = sp.getBool('videoMuted') ?? startMuted.value;
    loop.value = sp.getBool('videoLoop') ?? true;
    speed.value = sp.getDouble('videoSpeed') ?? 1;
    startMuted.addListener(() {
      sp.setBool('startMuted', startMuted.value);
      muted.value = startMuted.value;
    });
    muted.addListener(() => sp.setBool('videoMuted', muted.value));
    loop.addListener(() => sp.setBool('videoLoop', loop.value));
    speed.addListener(() => sp.setDouble('videoSpeed', speed.value));
    for (final k in sp.getKeys().where((k) => k.startsWith('vpos:'))) {
      _pos[k.substring(5)] = sp.getInt(k) ?? 0;
    }
  }

  static int resumeAt(String url) => _pos[url] ?? 0;

  /// Remember where you left off (skip near the start/end and short clips).
  static void savePos(String url, Duration at, Duration total) {
    final keep = total.inSeconds >= 20 && at.inSeconds > 3 && at < total - const Duration(seconds: 3);
    if (keep) {
      _pos[url] = at.inMilliseconds;
      _sp?.setInt('vpos:$url', at.inMilliseconds);
    } else if (_pos.remove(url) != null) {
      _sp?.remove('vpos:$url');
    }
  }
}

String fmtDur(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, ss = s % 60;
  String two(int x) => x.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(ss)}' : '$m:${two(ss)}';
}

/// Sources to try in order: HLS (has sound) or the resolved mp4, then the plain mp4, then Reddit's preview clip.
Future<List<(String, bool)>> videoSources(MediaItem it) async {
  final out = <(String, bool)>[];
  final hls = it.hls ?? Embeds.redditHls(it.url);
  if (hls != null) out.add((hls, true));
  try {
    out.add((await Embeds.playable(it.url), false));
  } catch (_) {}
  if (it.preview != null && it.preview!.isNotEmpty) out.add((it.preview!, false));
  return out;
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
  bool ui = true, full = false, dragging = false;
  double dragTo = 0;
  Timer? hide;
  String? flash; // "-10s" / "+10s"
  Timer? flashT;

  @override
  void initState() {
    super.initState();
    if (widget.active) _init(); // neighbours stay cold: at most the visible video holds a decoder
  }

  bool _initing = false, _wasPlaying = false;
  DateTime _lastSave = DateTime(2000);

  Future<void> _init() async {
    if (_initing || c != null) return;
    _initing = true;
    try {
      await _open();
    } finally {
      _initing = false;
    }
  }

  void _release() {
    final v = c;
    if (v == null) return;
    if (v.value.isInitialized) VideoPrefs.savePos(widget.item.url, v.value.position, v.value.duration);
    v.removeListener(_tick);
    v.dispose();
    c = null;
    if (_wasPlaying) WakelockPlus.disable();
    _wasPlaying = false;
  }

  Future<void> _open() async {
    final srcs = await videoSources(widget.item);
    Object? last;
    for (final (u, hls) in srcs) {
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(u),
          formatHint: hls ? VideoFormat.hls : null, httpHeaders: const {'User-Agent': Embeds.ua});
      try {
        await ctrl.initialize();
        await ctrl.setLooping(VideoPrefs.loop.value);
        await ctrl.setVolume(VideoPrefs.muted.value ? 0 : 1);
        await ctrl.setPlaybackSpeed(VideoPrefs.speed.value);
        final at = VideoPrefs.resumeAt(widget.item.url);
        if (at > 0) await ctrl.seekTo(Duration(milliseconds: at));
        if (!mounted || !widget.active) {
          await ctrl.dispose();
          return;
        }
        ctrl.addListener(_tick);
        setState(() => c = ctrl);
        if (widget.active) _play();
        return;
      } catch (e) {
        last = e;
        ctrl.dispose();
      }
    }
    if (mounted) setState(() => err = last == null ? 'No playable source' : '$last');
  }

  void _tick() {
    final v = c!.value;
    if (v.isPlaying != _wasPlaying) {
      _wasPlaying = v.isPlaying;
      v.isPlaying ? WakelockPlus.enable() : WakelockPlus.disable();
    }
    final now = DateTime.now();
    if (v.isInitialized && now.difference(_lastSave).inSeconds >= 5) {
      _lastSave = now; // was a prefs write on every frame tick
      VideoPrefs.savePos(widget.item.url, v.position, v.duration);
    }
    if (mounted && !dragging) setState(() {});
  }

  void _play() {
    c?.play();
    _autoHide();
  }

  void _autoHide() {
    hide?.cancel();
    hide = Timer(const Duration(seconds: 3), () {
      if (mounted && (c?.value.isPlaying ?? false) && !dragging) setState(() => ui = false);
    });
  }

  void _toggleUi() {
    setState(() => ui = !ui);
    if (ui) _autoHide();
  }

  void _skip(int s) {
    final v = c;
    if (v == null) return;
    var to = v.value.position + Duration(seconds: s);
    if (to < Duration.zero) to = Duration.zero;
    if (to > v.value.duration) to = v.value.duration;
    v.seekTo(to);
    flashT?.cancel();
    setState(() => flash = s > 0 ? '+${s}s' : '${s}s');
    flashT = Timer(const Duration(milliseconds: 600), () => mounted ? setState(() => flash = null) : null);
  }

  Future<void> _fullscreen() async {
    full = !full;
    if (full) {
      final ar = c?.value.aspectRatio ?? 1.7;
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(ar >= 1
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp]);
    } else {
      await _exitFull();
    }
    if (mounted) setState(() {});
  }

  Future<void> _exitFull() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations([]);
  }

  @override
  void didUpdateWidget(VideoPage old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    if (widget.active) {
      if (c == null) {
        _init();
      } else {
        _play();
      }
    } else {
      if (full) {
        full = false;
        _exitFull();
      }
      _release(); // free the decoder as soon as you swipe away
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    hide?.cancel();
    flashT?.cancel();
    _release();
    WakelockPlus.disable();
    if (full) _exitFull();
    super.dispose();
  }

  Widget _btn(IconData i, VoidCallback f, {String? tip, bool on = true}) => IconButton(
        tooltip: tip,
        icon: Icon(i, color: on ? Colors.white : Colors.white38, size: 22),
        onPressed: () {
          f();
          _autoHide();
        },
      );

  @override
  Widget build(BuildContext context) {
    if (err != null) {
      return Center(child: Text("Can't play this one\n$err", style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center));
    }
    final v = c;
    if (v == null) return const Center(child: CircularProgressIndicator());
    final val = v.value;
    final total = val.duration;
    final pos = dragging ? Duration(milliseconds: dragTo.round()) : val.position;
    final w = MediaQuery.sizeOf(context).width;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleUi,
      onDoubleTapDown: (d) => _skip(d.localPosition.dx < w / 2 ? -10 : 10),
      onDoubleTap: () {},
      child: Container(
        color: Colors.black,
        child: Stack(alignment: Alignment.center, children: [
          Center(child: AspectRatio(aspectRatio: val.aspectRatio, child: VideoPlayer(v))),
          if (val.isBuffering) const CircularProgressIndicator(color: Colors.white70),
          if (flash != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: Text(flash!, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
            ),
          IgnorePointer(
            ignoring: !ui,
            child: AnimatedOpacity(
              opacity: ui ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Stack(alignment: Alignment.center, children: [
                Material(
                  color: Colors.black45,
                  shape: const CircleBorder(),
                  child: IconButton(
                    iconSize: 56,
                    icon: Icon(val.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                    onPressed: () {
                      if (val.isPlaying) {
                        v.pause();
                        hide?.cancel();
                      } else {
                        if (val.position >= total && total > Duration.zero) v.seekTo(Duration.zero);
                        _play();
                      }
                    },
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: full ? 8 : 56,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent]),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        Text(fmtDur(pos), style: const TextStyle(color: Colors.white, fontSize: 12)),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              activeTrackColor: const Color(0xFFE53935),
                              thumbColor: const Color(0xFFE53935),
                              inactiveTrackColor: Colors.white24,
                            ),
                            child: Slider(
                              value: pos.inMilliseconds.clamp(0, total.inMilliseconds).toDouble(),
                              max: total.inMilliseconds <= 0 ? 1 : total.inMilliseconds.toDouble(),
                              onChangeStart: (x) => setState(() {
                                dragging = true;
                                dragTo = x;
                                hide?.cancel();
                              }),
                              onChanged: (x) => setState(() => dragTo = x),
                              onChangeEnd: (x) async {
                                await v.seekTo(Duration(milliseconds: x.round()));
                                if (!mounted) return;
                                setState(() => dragging = false);
                                _autoHide();
                              },
                            ),
                          ),
                        ),
                        Text(fmtDur(total), style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ]),
                      Row(children: [
                        _btn(VideoPrefs.muted.value ? Icons.volume_off : Icons.volume_up, () {
                          VideoPrefs.muted.value = !VideoPrefs.muted.value;
                          v.setVolume(VideoPrefs.muted.value ? 0 : 1);
                          setState(() {});
                        }, tip: 'Sound'),
                        _btn(Icons.repeat, () {
                          VideoPrefs.loop.value = !VideoPrefs.loop.value;
                          v.setLooping(VideoPrefs.loop.value);
                          setState(() {});
                        }, tip: 'Loop', on: VideoPrefs.loop.value),
                        PopupMenuButton<double>(
                          tooltip: 'Speed',
                          initialValue: VideoPrefs.speed.value,
                          onSelected: (s) {
                            VideoPrefs.speed.value = s;
                            v.setPlaybackSpeed(s);
                            _autoHide();
                          },
                          itemBuilder: (_) => [
                            for (final s in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]) PopupMenuItem(value: s, child: Text('${s}x')),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            child: Text('${VideoPrefs.speed.value}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                          ),
                        ),
                        const Spacer(),
                        _btn(Icons.replay_10, () => _skip(-10), tip: 'Back 10s'),
                        _btn(Icons.forward_10, () => _skip(10), tip: 'Ahead 10s'),
                        _btn(full ? Icons.fullscreen_exit : Icons.fullscreen, _fullscreen, tip: 'Full screen'),
                      ]),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
