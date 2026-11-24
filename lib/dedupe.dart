import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'db.dart';
import 'embeds.dart';
import 'models.dart';

/// Duplicate collapsing for reposts / crossposts of the same image or gallery.
///
/// 1. Exact keys: crosspost_parent, i.redd.it / i.imgur filename, gallery media_id set, preview source path,
///    video file ids (v.redd.it, RedGIFs, Imgur gifv/mp4).
/// 2. Perceptual: 64-bit dHash of a small thumbnail (algorithm as in JohannesBuchner/imagehash `dhash`),
///    computed in an isolate, cached in SQLite, grouped at Hamming distance <= [maxDistance].
///    Galleries match when most of their hashed images match.
/// Settings → 'Compare video frames' (off by default): grab 4 frames of videos on screen and match
/// re-uploads by their content. Costs data and time, so it runs one video at a time.
final videoFrameHashing = ValueNotifier<bool>(false);

class VideoFrames {
  final double seconds;
  final List<int> hashes; // one per [Dedupe.frameSpots]
  const VideoFrames(this.seconds, this.hashes);
}

class Dedupe {
  static const maxDistance = 6;
  /// Single videos of the same length (within [videoSeconds]) match at this looser thumbnail distance.
  static const videoDistance = 12;
  static const videoSeconds = 1.0;

  /// Frame spots (percent of the length) for [videoFrameHashing], and how close each frame must be.
  static const frameSpots = [10, 40, 70, 90];
  static const frameDistance = 10;
  static final Map<String, VideoFrames?> _frames = {}; // video url -> frames (null = failed)
  static final Set<String> _framePending = {};
  static final List<String> _frameQueue = [];
  static bool _frameRunning = false;

  /// Grabs and hashes the frames of a video file. Test seam; the app uses Android's MediaMetadataRetriever.
  static Future<VideoFrames?> Function(String url) grabFrames = _nativeFrames;

  @visibleForTesting
  static void debugSetFrames(String url, VideoFrames? f) => _frames[url] = f;

  /// Playable file for frame grabbing: Reddit's own mp4 or an Imgur mp4. RedGIFs/Streamable need
  /// resolving first and are skipped.
  static String? frameUrl(Post p) {
    if (!isSingleVideo(p)) return null;
    final m = p.media.first;
    if (m.redditVideo && m.url.contains('v.redd.it/')) return m.url;
    if (RegExp(r'^https://i\.imgur\.com/[A-Za-z0-9]+\.mp4$').hasMatch(m.url)) return m.url;
    return null;
  }

  /// Ask for this video's frames (called for tiles on screen, so only videos in view cost data).
  /// One video at a time, newest request first. Results bump [version] so the grid regroups.
  static void wantFrames(Post p) {
    if (!videoFrameHashing.value) return;
    final u = frameUrl(p);
    if (u == null || _frames.containsKey(u) || !_framePending.add(u)) return;
    _frameQueue.add(u);
    _pumpFrames();
  }

  static void _pumpFrames() {
    if (_frameRunning || _frameQueue.isEmpty) return;
    _frameRunning = true;
    final u = _frameQueue.removeLast();
    _loadFrames(u).then((f) => _frames[u] = f, onError: (_) => _frames[u] = null).whenComplete(() {
      _frameRunning = false;
      _framePending.remove(u);
      _bump ??= Timer(const Duration(milliseconds: 2000), () {
        _bump = null;
        version.value++;
      });
      _pumpFrames();
    });
  }

  static List<String> _frameKeys(String u) => ['$u#d', for (final t in frameSpots) '$u#t$t'];

  /// Cached in the phash table: `url#d` = length in ms (0 = failed), `url#t10` … = frame hashes.
  static Future<VideoFrames?> _loadFrames(String u) async {
    final keys = _frameKeys(u);
    final got = await Db.hashes(keys);
    if (got.length == keys.length) return _fromCache(got, keys);
    final f = await grabFrames(u);
    await Db.setHash(keys[0], f == null ? 0 : (f.seconds * 1000).round());
    if (f != null) {
      for (var k = 0; k < frameSpots.length; k++) {
        await Db.setHash(keys[k + 1], f.hashes[k]);
      }
    }
    return f;
  }

  static VideoFrames? _fromCache(Map<String, int?> got, List<String> keys) {
    final ms = got[keys[0]] ?? 0;
    final hs = [for (final k in keys.skip(1)) got[k]];
    if (ms <= 0 || hs.any((h) => h == null)) return null;
    return VideoFrames(ms / 1000, hs.cast<int>());
  }

  static const _media = MethodChannel('hobee/media');

  static Future<VideoFrames?> _nativeFrames(String url) async {
    final r = await _media.invokeMapMethod<String, dynamic>('frames', {
      'url': url,
      'ua': 'android:io.github.cscott0108.hobees:v1.3.7 (personal gallery app)',
      'spots': frameSpots,
    });
    final ms = (r?['durationMs'] as num?)?.toInt() ?? 0;
    final frames = (r?['frames'] as List?) ?? const [];
    if (ms <= 0 || frames.length != frameSpots.length) return null;
    final hs = <int>[];
    for (final b in frames) {
      final h = b is Uint8List && b.isNotEmpty ? await compute(dHash, b) : null;
      if (h == null) return null;
      hs.add(h);
    }
    return VideoFrames(ms / 1000, hs);
  }

  /// One video (or animated) item; compared only with other single videos.
  static bool isSingleVideo(Post p) => p.media.length == 1 && p.media.first.type != MediaType.image;

  /// Test seam: put a known thumbnail hash in the memory cache.
  @visibleForTesting
  static void debugSetHash(String url, int? hash) => _mem[url] = hash;
  static const _maxPerPost = 4; // hash at most this many images per gallery
  static const _bands = maxDistance + 1; // 7 bands of 9 bits (last one 10)
  static const _bandBits = 9;
  static const _bandMask = (1 << 10) - 1; // last band: bits 54..63
  static const _bandMask9 = (1 << 9) - 1;
  static final Map<String, int?> _mem = {}; // thumb url -> hash (null = failed)
  static final Map<String, List<String>> _keys = {}; // post id -> exact keys (posts don't change)
  static final Set<String> _pending = {};
  static final version = ValueNotifier<int>(0); // bumps when new hashes arrive
  static Timer? _bump;
  static int _running = 0;
  static final List<String> _queue = [];

  /// Groups [posts] (already ordered); returns representatives in order and a map rep.id -> all copies (incl. rep).
  static (List<Post>, Map<String, List<Post>>) collapse(List<Post> posts) {
    final n = posts.length;
    final parent = List<int>.generate(n, (i) => i);
    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    void union(int a, int b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[rb < ra ? ra : rb] = rb < ra ? rb : ra; // keep the earliest index as root
    }

    // 1) exact keys
    final seen = <String, int>{};
    for (var i = 0; i < n; i++) {
      for (final k in _keys.putIfAbsent(posts[i].id, () => exactKeys(posts[i]).toList())) {
        final j = seen[k];
        if (j == null) {
          seen[k] = i;
        } else {
          union(i, j);
        }
      }
    }

    // 2) perceptual hashes (whatever is cached so far; missing ones are queued)
    final hashes = List<List<int>>.generate(n, (i) {
      final out = <int>[];
      for (final m in posts[i].media.take(_maxPerPost)) {
        if (m.thumb.isEmpty) continue;
        final h = _mem[m.thumb];
        if (h != null) {
          out.add(h);
        } else if (!_mem.containsKey(m.thumb)) {
          _enqueue(m.thumb);
        }
      }
      return out;
    });
    // Candidate pairs via band buckets instead of all-pairs: a 64-bit hash split into
    // maxDistance + 1 bands; two hashes within maxDistance bits must agree exactly on at least
    // one band (pigeonhole), so only posts sharing a band bucket are compared. Same result,
    // roughly linear instead of quadratic on big profiles.
    final video = [for (final p in posts) isSingleVideo(p)];
    final dur = [for (var i = 0; i < n; i++) video[i] ? posts[i].media.first.duration : null];
    final buckets = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      final hs = hashes[i];
      if (hs.isEmpty) continue;
      if (video[i] && dur[i] != null) continue; // compared by duration below
      // Kinds never match each other: single picture 0, gallery 1, single video 2.
      final kind = video[i] ? 2 : (hs.length == 1 ? 0 : 1);
      for (final h in hs) {
        for (var b = 0; b < _bands; b++) {
          final key = (((h >> (b * _bandBits)) & (b == _bands - 1 ? _bandMask : _bandMask9)) << 8) | (b << 2) | kind;
          (buckets[key] ??= <int>[]).add(i);
        }
      }
    }
    final tried = <int>{};
    for (final list in buckets.values) {
      if (list.length < 2) continue;
      for (var a = 0; a < list.length; a++) {
        for (var b = a + 1; b < list.length; b++) {
          final i = list[a], j = list[b];
          if (i == j || find(i) == find(j)) continue;
          final pair = i < j ? i * n + j : j * n + i;
          if (!tried.add(pair)) continue;
          if (_similar(hashes[i], hashes[j])) union(i, j);
        }
      }
    }

    // 3) single videos with a known duration: re-uploads get a different poster frame, so the thumbnail
    //    may differ more than a picture's would. Same length (±[videoSeconds]) + loose distance ([videoDistance]).
    _byLength(dur, (i, j) => find(i) == find(j), (i, j) {
      if (hashes[i].isNotEmpty && hashes[j].isNotEmpty && hamming(hashes[i][0], hashes[j][0]) <= videoDistance) union(i, j);
    });

    // 4) optional (Settings → Compare video frames): frames at 10/40/70/90 % of videos seen so far.
    //    Same length (from the file itself) and most frames alike → same video, whatever the poster frame.
    if (videoFrameHashing.value) {
      final fr = [for (var i = 0; i < n; i++) video[i] ? _frames[frameUrl(posts[i]) ?? ''] : null];
      _byLength([for (final f in fr) f?.seconds], (i, j) => find(i) == find(j), (i, j) {
        if (framesMatch(fr[i]!.hashes, fr[j]!.hashes)) union(i, j);
      });
    }

    final groups = <int, List<Post>>{};
    for (var i = 0; i < n; i++) {
      groups.putIfAbsent(find(i), () => []).add(posts[i]);
    }
    final reps = <Post>[];
    final copies = <String, List<Post>>{};
    for (var i = 0; i < n; i++) {
      if (find(i) != i) continue;
      final g = groups[i]!;
      // Show the best copy (Live > Archive > Removed, then biggest image) at the slot of the earliest one.
      final best = g.length == 1 ? g.first : g.reduce((a, b) => quality(b) > quality(a) ? b : a);
      reps.add(best);
      if (g.length > 1) copies[best.id] = [best, ...g.where((p) => !identical(p, best))];
    }
    return (reps, copies);
  }

  /// Higher is better: live beats archived beats removed, then resolution of the preview source.
  static int quality(Post p) {
    final r = p.raw;
    final removed = r['removed_by_category'] != null || r['author'] == '[deleted]' || r['selftext'] == '[removed]' || r['selftext'] == '[deleted]';
    final tier = r['_hobee_live'] == true ? 2 : (removed ? 0 : 1);
    var px = 0;
    try {
      final s = r['preview']['images'][0]['source'];
      px = ((s['width'] as num) * (s['height'] as num)).toInt();
    } catch (_) {}
    return tier * 1000000000 + px.clamp(0, 999999999);
  }

  static bool _similar(List<int> a, List<int> b) {
    if (a.length == 1) return hamming(a[0], b[0]) <= maxDistance;
    var hit = 0;
    for (final x in a) {
      if (b.any((y) => hamming(x, y) <= maxDistance)) hit++;
    }
    final need = ((a.length < b.length ? a.length : b.length) * 0.6).ceil();
    return hit >= need;
  }

  /// Calls [match] for every pair whose lengths are within [videoSeconds] (null lengths are skipped).
  /// Bucketed by rounded seconds; lengths within 1 s are at most one bucket apart, so this is near linear.
  static void _byLength(List<double?> secs, bool Function(int, int) same, void Function(int, int) match) {
    final by = <int, List<int>>{};
    for (var i = 0; i < secs.length; i++) {
      if (secs[i] != null) (by[secs[i]!.round()] ??= <int>[]).add(i);
    }
    for (final MapEntry(key: s, value: list) in by.entries) {
      final next = by[s + 1] ?? const <int>[];
      for (var a = 0; a < list.length; a++) {
        final i = list[a];
        for (final j in [...list.skip(a + 1), ...next]) {
          if (same(i, j) || (secs[i]! - secs[j]!).abs() > videoSeconds) continue;
          match(i, j);
        }
      }
    }
  }

  /// Frame hashes taken at the same spots: a match when at least 3 of 4 spots are within [frameDistance].
  static bool framesMatch(List<int> a, List<int> b) {
    if (a.isEmpty || a.length != b.length) return false;
    var hit = 0;
    for (var k = 0; k < a.length; k++) {
      if (hamming(a[k], b[k]) <= frameDistance) hit++;
    }
    return hit * 4 >= a.length * 3;
  }

  static int hamming(int a, int b) {
    var x = a ^ b, c = 0;
    while (x != 0) {
      x &= x - 1;
      c++;
    }
    return c;
  }

  static final _file = RegExp(r'(?:i\.redd\.it|i\.imgur\.com|preview\.redd\.it|external-preview\.redd\.it)/([A-Za-z0-9_-]+)');

  static final _vReddit = RegExp(r'v\.redd\.it/([A-Za-z0-9]+)');
  static final _imgurVideo = RegExp(r'imgur\.com/([A-Za-z0-9]{5,8})\.(?:gifv|mp4)(?:[?#]|$)', caseSensitive: false);

  /// Video file ids of a single-media post: v.redd.it id, RedGIFs id, Imgur .gifv/.mp4 id (all hosts).
  /// Looks at the media item, the post URL, and reddit_video fallback/HLS/DASH urls (own and crosspost parent).
  static Iterable<String> videoKeys(Post p) sync* {
    final r = p.raw;
    final m = p.media.first;
    final urls = <String>{m.url, ?m.hls, '${r['url'] ?? ''}', '${r['url_overridden_by_dest'] ?? ''}'};
    final cp = r['crosspost_parent_list'];
    for (final d in [r, if (cp is List && cp.isNotEmpty && cp.first is Map) cp.first as Map]) {
      for (final k in ['secure_media', 'media']) {
        final rv = d[k] is Map ? (d[k] as Map)['reddit_video'] : null;
        if (rv is Map) {
          for (final f in ['fallback_url', 'hls_url', 'dash_url']) {
            if (rv[f] is String) urls.add(rv[f] as String);
          }
        }
      }
    }
    final out = <String>{};
    for (final u in urls) {
      if (u.isEmpty) continue;
      final v = _vReddit.firstMatch(u);
      if (v != null) out.add('v:vr:${v.group(1)}');
      final rg = Embeds.redgifsId(u);
      if (rg != null) out.add('v:rg:$rg');
      final im = _imgurVideo.firstMatch(u);
      if (im != null) out.add('v:im:${im.group(1)}');
    }
    yield* out;
  }

  static Iterable<String> exactKeys(Post p) sync* {
    final r = p.raw;
    final cp = r['crosspost_parent'];
    if (cp is String && cp.isNotEmpty) yield 'cp:${cp.replaceFirst('t3_', '')}';
    yield 'id:${p.id}'; // same post from Live + Arctic Shift + PullPush
    yield 'cp:${p.id}'; // the original of a crosspost collapses with its crossposts
    final meta = r['media_metadata'];
    if (meta is Map && meta.isNotEmpty) {
      final ids = meta.keys.map((k) => '$k').toList()..sort();
      yield 'gal:${ids.join(',')}';
      return;
    }
    if (p.media.length == 1) {
      yield* videoKeys(p);
      for (final u in [p.media.first.url, '${r['url'] ?? ''}']) {
        final m = _file.firstMatch(originalOf(u));
        if (m != null) yield 'f:${m.group(1)}';
      }
      try {
        final src = '${r['preview']['images'][0]['source']['url']}';
        final m = _file.firstMatch(originalOf(src));
        if (m != null) yield 'f:${m.group(1)}';
      } catch (_) {}
    }
  }

  // ---- hashing ----

  /// Loads cached hashes for these thumbs from SQLite (call before [collapse]).
  static Future<void> warm(List<Post> posts) async {
    final urls = <String>{
      for (final p in posts)
        for (final m in p.media.take(_maxPerPost))
          if (m.thumb.isNotEmpty && !_mem.containsKey(m.thumb)) m.thumb
    };
    if (urls.isNotEmpty) _mem.addAll(await Db.hashes(urls.toList()));
    if (!videoFrameHashing.value) return;
    final vids = {for (final p in posts) ?frameUrl(p)}..removeWhere(_frames.containsKey);
    if (vids.isEmpty) return;
    final got = await Db.hashes([for (final u in vids) ..._frameKeys(u)]);
    for (final u in vids) {
      final keys = _frameKeys(u);
      if (keys.every(got.containsKey)) _frames[u] = _fromCache(got, keys);
    }
  }

  static void _enqueue(String url) {
    if (_pending.add(url)) {
      _queue.add(url);
      _pump();
    }
  }

  static void _pump() {
    while (_running < 4 && _queue.isNotEmpty) {
      final u = _queue.removeAt(0);
      _running++;
      _hashUrl(u).then((h) async {
        _mem[u] = h;
        await Db.setHash(u, h);
      }).whenComplete(() {
        _running--;
        _pending.remove(u);
        _bump ??= Timer(const Duration(milliseconds: 2000), () {
          _bump = null;
          version.value++;
        });
        _pump();
      });
    }
  }

  /// Cached hash for a thumb (memory, then SQLite); [fetch] downloads and hashes when missing.
  static Future<int?> hashFor(String url, {bool fetch = true}) async {
    if (url.isEmpty) return null;
    if (_mem.containsKey(url)) return _mem[url];
    final got = await Db.hashes([url]);
    if (got.containsKey(url)) return _mem[url] = got[url];
    if (!fetch) return null;
    final h = await _hashUrl(url);
    _mem[url] = h;
    await Db.setHash(url, h);
    return h;
  }

  static int? cachedHash(String url) => _mem[url];
  static bool known(String url) => _mem.containsKey(url);
  static const maxPerPost = _maxPerPost;
  static const maxHashBytes = 2 << 20;

  static Future<int?> _hashUrl(String url) async {
    try {
      final r = await http.get(Uri.parse(url), headers: {'User-Agent': 'android:io.github.cscott0108.hobees:v1.3.7 (personal gallery app)'}).timeout(const Duration(seconds: 15));
      // Big files (full size photos, long GIFs) would need a lot of memory to decode; they are skipped.
      if (r.statusCode != 200 || r.bodyBytes.isEmpty || r.bodyBytes.length > maxHashBytes) return null;
      return await compute(dHash, r.bodyBytes);
    } catch (_) {
      return null;
    }
  }
}

/// 64-bit difference hash: grayscale, resize to 9x8, bit = left pixel brighter than right.
int? dHash(Uint8List bytes) {
  if (bytes.length > Dedupe.maxHashBytes) return null;
  final im = img.decodeImage(bytes, frame: 0); // first frame only, never every frame of a GIF
  if (im == null) return null;
  final s = img.copyResize(img.grayscale(im), width: 9, height: 8, interpolation: img.Interpolation.average);
  var h = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      h = (h << 1) | (s.getPixel(x, y).luminance > s.getPixel(x + 1, y).luminance ? 1 : 0);
    }
  }
  return h;
}
