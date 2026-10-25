import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hobee/archive.dart';
import 'package:hobee/dedupe.dart';
import 'package:hobee/models.dart';

Post post(String id, Map<String, dynamic> extra) =>
    Post.fromJson({'id': id, 'title': 't', 'subreddit': 's', 'author': 'a', 'permalink': '/p', 'created_utc': 0, ...extra})!;

Map<String, dynamic> img(String id, {int w = 100, int h = 100}) => {
      'url': 'https://i.redd.it/$id.jpeg',
      'post_hint': 'image',
      'preview': {
        'images': [
          {'source': {'url': 'https://preview.redd.it/$id.jpeg?auto=webp&amp;s=abc', 'width': w, 'height': h}, 'resolutions': []}
        ]
      },
    };

void main() {
  final cache = <String, String>{};
  setUp(() {
    cache.clear();
    MediaCheck.reset();
    MediaCheck.retries = 0;
    MediaCheck.readCache = (k) async => cache[k];
    MediaCheck.writeCache = (k, v) async => cache[k] = v;
    MediaCheck.wayback = (_) async => null;
  });

  test('deleted preview that answers 206 to a Range request is not trusted (the v1.3.6 bug)', () async {
    // preview.redd.it: 206 for ranged GETs of deleted images, 404 for a normal GET.
    MediaCheck.client = () => MockClient((rq) async => http.Response('', rq.headers.containsKey('range') ? 206 : 404));
    final p = post('a1', img('deadimage123'));
    expect(await MediaCheck.resolve(p, p.media.first, thumb: true), isNull);
    expect(MediaCheck.gone.value, contains('a1'));
  });

  test('preview HTML entities are unescaped and the live preview is picked', () async {
    final seen = <String>[];
    MediaCheck.client = () => MockClient((rq) async {
          seen.add('${rq.url}');
          return http.Response('x', rq.url.host == 'preview.redd.it' ? 200 : 404);
        });
    final p = post('a2', img('liveprev1234'));
    final u = await MediaCheck.resolve(p, p.media.first);
    expect(u, 'https://preview.redd.it/liveprev1234.jpeg?auto=webp&s=abc');
    expect(seen.any((s) => s.contains('&amp;')), isFalse);
  });

  test('wayback copy is used when every reddit url is gone', () async {
    MediaCheck.client = () => MockClient((rq) async => http.Response('', 404));
    MediaCheck.wayback = (u) async => u.contains('i.redd.it') ? 'https://web.archive.org/web/1id_/$u' : null;
    final p = post('a3', img('waybackonly1'));
    expect(await MediaCheck.resolve(p, p.media.first), startsWith('https://web.archive.org/'));
  });

  test('forget lets a retry check again', () async {
    var code = 404;
    MediaCheck.client = () => MockClient((rq) async => http.Response('x', code));
    final p = post('a4', img('flakyimage12'));
    expect(await MediaCheck.resolve(p, p.media.first), isNull);
    code = 200;
    await MediaCheck.forget(p, p.media.first);
    expect(await MediaCheck.resolve(p, p.media.first), isNotNull);
  });

  group('dedupe', () {
    test('same post from live and archive shows once, live copy wins', () {
      final arch = post('x1', img('sameimage123'));
      final live = post('x1', {...img('sameimage123'), '_hobee_live': true});
      final (reps, copies) = Dedupe.collapse([arch, live]);
      expect(reps.length, 1);
      expect(identical(reps.first, live), isTrue);
      expect(copies[live.id]!.length, 2);
    });

    test('reupload of the same file in another post collapses, removed copy loses', () {
      final removed = post('r1', {...img('reuploadimg1', w: 2000, h: 2000), 'removed_by_category': 'deleted'});
      final archived = post('r2', img('reuploadimg1', w: 500, h: 500));
      final other = post('r3', img('differentimg'));
      final (reps, _) = Dedupe.collapse([removed, archived, other]);
      expect(reps.map((p) => p.id), ['r2', 'r3']);
    });

    test('imgur size suffix and query params do not hide a duplicate', () {
      final a = post('i1', {'url': 'https://i.imgur.com/AbCdEfG.jpg', 'post_hint': 'image'});
      final b = post('i2', {'url': 'https://i.imgur.com/AbCdEfGh.jpg?1', 'post_hint': 'image'});
      expect(Dedupe.collapse([a, b]).$1.length, 1);
    });

    test('crosspost collapses with its parent', () {
      final parent = post('p1', img('parentimage1'));
      final cross = post('c1', {...img('otherfile123'), 'crosspost_parent': 't3_p1'});
      expect(Dedupe.collapse([parent, cross]).$1.length, 1);
    });
  });
}
