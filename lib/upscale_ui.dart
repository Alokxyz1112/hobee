import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'download.dart';
import 'glass.dart';
import 'models.dart';
import 'upscale.dart';

/// Opens the upscale picker for one image, then the result screen. Unlimited and free, nothing is locked.
Future<void> showUpscale(BuildContext context, MediaItem item, String baseName) async {
  final pick = await showModalBottomSheet<(int, UpModel, PostOptions)>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _Picker(),
  );
  if (pick == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => UpscaleScreen(item: item, scale: pick.$1, model: pick.$2, post: pick.$3, baseName: baseName)));
}

class _Picker extends StatefulWidget {
  const _Picker();
  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  int scale = 2;
  UpModel model = UpModel.fast;
  bool natural = true, grain = false, color = false;
  final Map<UpModel, bool> _ready = {};

  @override
  void initState() {
    super.initState();
    for (final m in UpModel.values) {
      Upscaler.ready(m).then((r) { if (mounted) setState(() => _ready[m] = r); });
    }
  }

  @override
  Widget build(BuildContext context) {
    const white = TextStyle(color: Colors.white);
    return Glass(
      radius: const BorderRadius.vertical(top: Radius.circular(24)),
      fill: Colors.black.withValues(alpha: 0.45),
      border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.15))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.auto_awesome, color: Colors.white),
              const SizedBox(width: 8),
              const Text('Upscale', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
              const Spacer(),
              SegmentedButton<int>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(foregroundColor: Colors.white, selectedForegroundColor: Colors.black, selectedBackgroundColor: Colors.white, visualDensity: VisualDensity.compact),
                segments: const [ButtonSegment(value: 2, label: Text('2x')), ButtonSegment(value: 3, label: Text('3x')), ButtonSegment(value: 4, label: Text('4x'))],
                selected: {scale},
                onSelectionChanged: (s) => setState(() => scale = s.first),
              ),
            ]),
            const SizedBox(height: 8),
            for (final m in UpModel.values)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                onTap: () => setState(() => model = m),
                leading: Icon(model == m ? Icons.radio_button_checked : Icons.radio_button_off, color: Colors.white),
                title: Text(m.label, style: white),
                trailing: Text('${estimateText(estimateSeconds(m, 1000, 1000))} / MP', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                subtitle: Text(
                    '${m.hint}${m.bundled ? '' : (_ready[m] ?? false) ? ' Downloaded.' : ' Downloads ${(m.approxBytes / 1e6).round()} MB once.'}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ),
            const SizedBox(height: 4),
            Row(children: [
              const Text('Look', style: white),
              const Spacer(),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(foregroundColor: Colors.white, selectedForegroundColor: Colors.black, selectedBackgroundColor: Colors.white, visualDensity: VisualDensity.compact),
                segments: const [ButtonSegment(value: true, label: Text('Natural')), ButtonSegment(value: false, label: Text('Sharp'))],
                selected: {natural},
                onSelectionChanged: (s) => setState(() => natural = s.first),
              ),
            ]),
            _switch('Restore color', 'Gentle boost for faded colors. Skin is left alone.', color, (v) => setState(() => color = v)),
            _switch('Film grain', 'Adds back a little grain matched to the photo.', grain, (v) => setState(() => grain = v)),
            const Text('Colors and skin tones are kept true to the original. Blocky JPEGs get extra cleanup on their own.',
                style: TextStyle(color: Colors.white54, fontSize: 11)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.auto_awesome),
                label: Text('Upscale ${scale}x'),
                onPressed: () => Navigator.pop(context, (scale, model, PostOptions(natural: natural ? 0.25 : 0, grain: grain, vibrance: color ? 0.12 : 0))),
              ),
            ),
          ])),
        ),
      ),
    );
  }
}

Widget _switch(String t, String sub, bool v, ValueChanged<bool> on) => SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      value: v,
      onChanged: on,
      title: Text(t, style: const TextStyle(color: Colors.white)),
      subtitle: Text(sub, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    );

class UpscaleScreen extends StatefulWidget {
  final MediaItem item;
  final int scale;
  final UpModel model;
  final PostOptions post;
  final String baseName;
  const UpscaleScreen({super.key, required this.item, required this.scale, required this.model, this.post = const PostOptions(), required this.baseName});
  @override
  State<UpscaleScreen> createState() => _UpscaleScreenState();
}

class _UpscaleScreenState extends State<UpscaleScreen> {
  String stage = 'Getting the image';
  double? progress;
  bool cancelled = false;
  Object? error;
  Uint8List? before;
  UpscaleResult? result;
  double split = 0.5;
  bool saving = false;
  final _clock = Stopwatch();

  String get _eta {
    final p = progress;
    if (p == null || p <= 0.02 || !_clock.isRunning) return '';
    final left = _clock.elapsedMilliseconds / 1000 / p * (1 - p);
    return left < 5 ? '  almost done' : '  ${estimateText(left).replaceFirst('About', 'about')} left';
  }

  @override
  void initState() {
    super.initState();
    _go();
  }

  @override
  void dispose() {
    cancelled = true;
    super.dispose();
  }

  Future<void> _go() async {
    setState(() { error = null; result = null; progress = null; });
    try {
      final m = widget.model;
      if (!await Upscaler.ready(m)) {
        setState(() => stage = 'Downloading ${m.label} model');
        await Upscaler.download(m, progress: (p) { if (mounted) setState(() => progress = p); }, cancelled: () => cancelled);
      }
      before ??= await Downloader.imageBytes(widget.item);
      if (!mounted) return;
      setState(() { stage = 'Upscaling ${widget.scale}x with ${m.label}'; progress = 0; });
      _clock..reset()..start();
      final r = await Upscaler.run(before!, widget.scale, m, post: widget.post,
          progress: (p) { if (mounted) setState(() => progress = p); }, cancelled: () => cancelled);
      _clock.stop();
      if (mounted) setState(() => result = r);
    } on UpscaleCancelled {
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (kDebugMode) debugPrint('upscale failed: $e');
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> _save() async {
    final r = result!;
    setState(() => saving = true);
    final m = ScaffoldMessenger.of(context);
    try {
      final f = File('${(await getTemporaryDirectory()).path}/up_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(r.png);
      await Downloader.saveFile(f.path, 'png', 'image/png');
      m.showSnackBar(SnackBar(content: Text('Saved ${r.w}x${r.h} PNG to Pictures')));
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        flexibleSpace: Glass(fill: Colors.black.withValues(alpha: 0.35), border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.15))), child: const SizedBox.expand()),
        title: Text(r == null ? 'Upscale ${widget.scale}x' : '${r.srcW}x${r.srcH} → ${r.w}x${r.h}', style: const TextStyle(fontSize: 15)),
        actions: [
          if (r != null)
            IconButton(
              tooltip: 'Save to gallery',
              onPressed: saving ? null : _save,
              icon: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_alt),
            ),
        ],
      ),
      body: error != null
          ? _center([
              const Icon(Icons.error_outline, color: Colors.white70, size: 40),
              const SizedBox(height: 8),
              Text(friendlyUpscaleError(error!), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              FilledButton.icon(onPressed: _go, icon: const Icon(Icons.refresh), label: const Text('Retry')),
            ])
          : r == null
              ? _center([
                  SizedBox(width: 220, child: LinearProgressIndicator(value: progress)),
                  const SizedBox(height: 12),
                  Text(progress == null ? stage : progress! >= 1 ? 'Finishing up' : '$stage  ${(progress! * 100).round()}%$_eta', style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                    onPressed: () { cancelled = true; if (result == null && progress == null) Navigator.pop(context); },
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel'),
                  ),
                ])
              : CompareView(before: before!, after: r.png, split: split, onSplit: (v) => setState(() => split = v), shrunk: r.shrunk),
    );
  }

  Widget _center(List<Widget> c) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: c)));
}

/// Before/after with a draggable divider. Long-press shows the original full screen.
class CompareView extends StatefulWidget {
  final Uint8List before, after;
  final double split;
  final ValueChanged<double> onSplit;
  final bool shrunk;
  const CompareView({super.key, required this.before, required this.after, required this.split, required this.onSplit, this.shrunk = false});
  @override
  State<CompareView> createState() => _CompareViewState();
}

class _CompareViewState extends State<CompareView> {
  bool peek = false;
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      final w = c.maxWidth;
      Widget pic(Uint8List b, FilterQuality q) => Image.memory(b, fit: BoxFit.contain, width: w, height: c.maxHeight, filterQuality: q, gaplessPlayback: true);
      final split = peek ? 1.0 : widget.split;
      return GestureDetector(
        onHorizontalDragUpdate: (d) => widget.onSplit((d.localPosition.dx / w).clamp(0.0, 1.0)),
        onTapDown: (d) => widget.onSplit((d.localPosition.dx / w).clamp(0.0, 1.0)),
        onLongPressStart: (_) => setState(() => peek = true),
        onLongPressEnd: (_) => setState(() => peek = false),
        child: InteractiveViewer(
          maxScale: 8,
          child: Stack(children: [
            pic(widget.after, FilterQuality.medium),
            // The original is drawn with nearest-neighbour scaling so you see its real pixels, not a smoothed guess.
            ClipRect(clipper: _Left(split), child: pic(widget.before, FilterQuality.none)),
            Positioned(left: split * w - 1, top: 0, bottom: 0, child: Container(width: 2, color: Colors.white70)),
            Positioned(left: 12, bottom: 24, child: _tag('Before')),
            Positioned(right: 12, bottom: 24, child: _tag(widget.shrunk ? 'After (big image, shrunk first)' : 'After')),
          ]),
        ),
      );
    });
  }

  Widget _tag(String t) => Glass(
      radius: BorderRadius.circular(12),
      fill: Colors.black.withValues(alpha: 0.4),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 12))));
}

class _Left extends CustomClipper<Rect> {
  final double f;
  _Left(this.f);
  @override
  Rect getClip(Size s) => Rect.fromLTWH(0, 0, s.width * f, s.height);
  @override
  bool shouldReclip(_Left o) => o.f != f;
}

/// Short message for the user. Details only go to the debug log.
String friendlyUpscaleError(Object e) {
  final t = e.toString().toLowerCase();
  if (t.contains('socket') || t.contains('http') || t.contains('download') || t.contains('connection')) {
    return 'Could not get the image or model. Check your connection and retry.';
  }
  if (t.contains('could not read')) return 'This image could not be read.';
  if (t.contains('memory')) return 'Not enough memory for this one. Try a smaller scale or the Fast model.';
  return 'Upscaling failed. Please retry.';
}
