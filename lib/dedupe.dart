import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'db.dart';
import 'models.dart';

/// Duplicate collapsing for reposts / crossposts of the same image or gallery.
///
/// 1. Exact keys: crosspost_parent, i.redd.it / i.imgur filename, gallery media_id set, preview source path.
/// 2. Perceptual: 64-bit dHash of a small thumbnail (algorithm as in JohannesBuchner/imagehash `dhash`),
///    computed in an isolate, cached in SQLite, grouped at Hamming distance <= [maxDistance].
///    Galleries match when most of their hashed images match.
class Dedupe {
  static const maxDistance = 6;
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
    final buckets = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      final hs = hashes[i];
      if (hs.isEmpty) continue;
      final kind = hs.length == 1 ? 0 : 1; // single vs gallery never match
      for (final h in hs) {
        for (var b = 0; b < _bands; b++) {
          final key = (((h >> (b * _bandBits)) & (b == _bands - 1 ? _bandMask : _bandMask9)) << 8) | (b << 1) | kind;
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

  static int hamming(int a, int b) {
    var x = a ^ b, c = 0;
    while (x != 0) {
      x &= x - 1;
      c++;
    }
    return c;
  }

  static final _file = RegExp(r'(?:i\.redd\.it|i\.imgur\.com|preview\.redd\.it|external-preview\.redd\.it)/([A-Za-z0-9_-]+)');

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
    if (urls.isEmpty) return;
    final got = await Db.hashes(urls.toList());
    _mem.addAll(got);
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

  static Future<int?> _hashUrl(String url) async {
    try {
      final r = await http.get(Uri.parse(url), headers: {'User-Agent': 'android:com.alok.hobee:v1.3.7 (personal gallery app)'}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      return await compute(dHash, r.bodyBytes);
    } catch (_) {
      return null;
    }
  }
}

/// 64-bit difference hash: grayscale, resize to 9x8, bit = left pixel brighter than right.
int? dHash(Uint8List bytes) {
  final im = img.decodeImage(bytes);
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
