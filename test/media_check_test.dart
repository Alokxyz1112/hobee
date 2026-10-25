import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hobee/archive.dart';
import 'package:hobee/models.dart';

/// Verbatim copy of the <=1.3.4 verdict rule (lib.bak-1.3.4-final/archive.dart MediaCheck._alive) for comparison.
bool? legacyVerdict(String url, int code, Map<String, String> h) {
  if (code == 404 || code == 410) return false;
  if (code >= 400) return null;
  final total = int.tryParse((h['content-range'] ?? '').split('/').last) ?? int.tryParse(h['content-length'] ?? '');
  if (Uri.parse(url).host.endsWith('redd.it') && total != null && total <= 2048) return false;
  return true;
}

Post post(String id, Map<String, dynamic> extra) =>
    Post.fromJson({'id': id, 'title': 't', 'subreddit': 's', 'author': 'a', 'permalink': '/p', 'created_utc': 0, ...extra})!;

void main() {
  final cache = <String, String>{};
  late Map<String, http.Response Function()> routes;
  setUp(() {
    cache.clear();
    MediaCheck.reset();
    MediaCheck.readCache = (k) async => cache[k];
    MediaCheck.writeCache = (k, v) async => cache[k] = v;
    MediaCheck.wayback = (_) async => null;
    MediaCheck.retries = 0;
    MediaCheck.client = () => MockClient((rq) async => (routes[rq.url.toString()] ?? () => http.Response('', 404))());
  });

  // Real CDN answer for a ranged GET of a live image when an edge omits Content-Range / uses "*":
  // 206 with Content-Length: 1. Also a genuinely tiny (<2 KB) valid preview thumbnail.
  http.Response r206() => http.Response('x', 206, headers: {'content-length': '1', 'content-range': 'bytes 0-0/*'});
  http.Response tiny() => http.Response('x', 206, headers: {'content-range': 'bytes 0-0/1800', 'content-length': '1'});

  test('legacy rule flagged valid images as gone (the bug)', () {
    expect(legacyVerdict('https://i.redd.it/abcdefgh12345.jpeg', 206, {'content-length': '1', 'content-range': 'bytes 0-0/*'}), false);
    expect(legacyVerdict('https://preview.redd.it/abcdefgh12345.jpeg?width=108', 206, {'content-range': 'bytes 0-0/1800'}), false);
  });

  test('valid image is never marked gone: 206 w/o total, tiny thumbs, 403, 429', () async {
    final p = post('a1', {'url': 'https://i.redd.it/abcdefgh12345.jpeg', 'post_hint': 'image'});
    for (final r in [r206, tiny, () => http.Response('', 403), () => http.Response('', 429)]) {
      MediaCheck.reset();
      cache.clear();
      routes = {'https://i.redd.it/abcdefgh12345.jpeg': r};
      expect(await MediaCheck.resolve(p, p.media.first), 'https://i.redd.it/abcdefgh12345.jpeg');
    }
    expect(cache.values.where((v) => v.isEmpty), isEmpty, reason: 'unsure results must not be cached as gone');
  });

  test('network error is unsure, not gone', () async {
    final p = post('a2', {'url': 'https://i.redd.it/zzzzzzzz12345.png', 'post_hint': 'image'});
    MediaCheck.client = () => MockClient((_) async => throw http.ClientException('offline'));
    expect(await MediaCheck.resolve(p, p.media.first), isNotNull);
  });

  test('positive evidence still marks gone: 404 everywhere, imgur removed redirect', () async {
    routes = {};
    final p = post('g1', {'url': 'https://i.redd.it/deadbeef12345.jpg', 'post_hint': 'image'});
    expect(await MediaCheck.resolve(p, p.media.first), isNull);
    expect(MediaCheck.verdict(Uri.parse('https://i.imgur.com/abc1234.jpg'), 302, 'https://i.imgur.com/removed.png'), false);
    expect(MediaCheck.verdict(Uri.parse('https://i.imgur.com/abc1234.jpg'), 302, 'https://imgur.com/abc1234'), false);
  });

  test('dead original falls back to live preview', () async {
    const pv = 'https://preview.redd.it/qqqqqqqq12345.jpeg?width=1080&auto=webp&s=abc';
    routes = {pv: () => http.Response('x', 200)};
    final p = post('f1', {'url': 'https://www.reddit.com/gallery/f1', 'post_hint': 'image', 'preview': {'images': [{'source': {'url': pv}, 'resolutions': []}]}});
    expect(p.media.first.url, 'https://i.redd.it/qqqqqqqq12345.jpeg');
    expect(await MediaCheck.resolve(p, p.media.first), pv);
  });

  test('original-quality mapping', () {
    expect(originalOf('https://preview.redd.it/9niq6f0aidxh1.jpeg?width=1080&amp;auto=webp&amp;s=1'), 'https://i.redd.it/9niq6f0aidxh1.jpeg');
    expect(originalOf('https://i.imgur.com/AbCdEfGh.jpg'), 'https://i.imgur.com/AbCdEfG.jpg');
    expect(originalOf('https://i.imgur.com/AbCdEfG.jpg'), 'https://i.imgur.com/AbCdEfG.jpg');
    final ext = 'https://external-preview.redd.it/NG4wNjBp-x.png?width=640&s=1';
    expect(originalOf(ext), ext);
    final g = post('gal', {'is_gallery': true, 'media_metadata': {'abc123def456': {'status': 'valid', 'e': 'Image', 'm': 'image/png',
        's': {'u': 'https://preview.redd.it/abc123def456.png?width=3000&amp;format=png&amp;auto=webp&amp;s=x'}, 'p': []}}});
    expect(g.media.first.url, 'https://i.redd.it/abc123def456.png');
    expect(g.media.first.preview, contains('preview.redd.it'));
    originalQuality.value = false;
    expect(g.media.first.full, contains('preview.redd.it'));
    originalQuality.value = true;
  });
}
