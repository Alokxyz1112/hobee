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

/// Dedupe.collapse without background work: thumbnails with no known hash are marked as failed
/// (null) first, so nothing is fetched or written to SQLite after the test ends.
(List<Post>, Map<String, List<Post>>) collapse(List<Post> posts) {
  for (final p in posts) {
    for (final m in p.media) {
      if (m.thumb.isNotEmpty && !Dedupe.known(m.thumb)) Dedupe.debugSetHash(m.thumb, null);
    }
  }
  return Dedupe.collapse(posts);
}

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
      final (reps, copies) = collapse([arch, live]);
      expect(reps.length, 1);
      expect(identical(reps.first, live), isTrue);
      expect(copies[live.id]!.length, 2);
    });

    test('reupload of the same file in another post collapses, removed copy loses', () {
      final removed = post('r1', {...img('reuploadimg1', w: 2000, h: 2000), 'removed_by_category': 'deleted'});
      final archived = post('r2', img('reuploadimg1', w: 500, h: 500));
      final other = post('r3', img('differentimg'));
      final (reps, _) = collapse([removed, archived, other]);
      expect(reps.map((p) => p.id), ['r2', 'r3']);
    });

    test('imgur size suffix and query params do not hide a duplicate', () {
      final a = post('i1', {'url': 'https://i.imgur.com/AbCdEfG.jpg', 'post_hint': 'image'});
      final b = post('i2', {'url': 'https://i.imgur.com/AbCdEfGh.jpg?1', 'post_hint': 'image'});
      expect(collapse([a, b]).$1.length, 1);
    });

    test('crosspost collapses with its parent', () {
      final parent = post('p1', img('parentimage1'));
      final cross = post('c1', {...img('otherfile123'), 'crosspost_parent': 't3_p1'});
      expect(collapse([parent, cross]).$1.length, 1);
    });
  });

  group('video dedupe', () {
    const far = 0xFFFFFFFF00000000; // 32 bits away from 0
    tearDown(() => videoFrameHashing.value = false);

    /// Reddit video post with its poster thumbnail hash set in the cache (no network).
    Post v(String id, String vid, int hash, {double? dur}) {
      final thumb = 'https://b.thumbs.redditmedia.com/$id.jpg';
      Dedupe.debugSetHash(thumb, hash);
      return post(id, {
        'url': 'https://v.redd.it/$vid',
        'thumbnail': thumb,
        'secure_media': {
          'reddit_video': {'fallback_url': 'https://v.redd.it/$vid/DASH_720.mp4?source=fallback', 'duration': ?dur}
        },
      });
    }

    test('duration is parsed from reddit_video', () {
      expect(v('d0', 'durvid00001', 0, dur: 12).media.single.duration, 12.0);
      expect(v('d1', 'durvid00002', 0).media.single.duration, isNull);
    });

    test('same v.redd.it id in different posts -> collapsed', () {
      final a = v('va1', 'samevideo01', 0, dur: 20);
      final link = post('va2', {
        'url': 'https://www.reddit.com/r/x/comments/va2/',
        'thumbnail': 'https://b.thumbs.redditmedia.com/va2.jpg',
        'media': {
          'reddit_video': {'fallback_url': 'https://v.redd.it/samevideo01/DASH_480.mp4', 'duration': 3}
        },
      });
      Dedupe.debugSetHash('https://b.thumbs.redditmedia.com/va2.jpg', far);
      expect(Dedupe.exactKeys(a), contains('v:vr:samevideo01'));
      expect(collapse([a, link]).$1.length, 1);
    });

    test('same duration with similar thumbnails -> collapsed (looser than pictures)', () {
      final a = v('vb1', 'reupload001', 0, dur: 30.2);
      final b = v('vb2', 'reupload002', (1 << 10) - 1, dur: 29.6); // 10 bits apart: too far for pictures
      expect(collapse([a, b]).$1.length, 1);
    });

    test('same duration with different thumbnails -> kept', () {
      final a = v('vc1', 'difvideo001', 0, dur: 15);
      final b = v('vc2', 'difvideo002', far, dur: 15);
      expect(collapse([a, b]).$1.length, 2);
    });

    test('lengths more than a second apart -> kept, even with the same thumbnail', () {
      final a = v('vd1', 'lenvideo001', 0, dur: 10);
      final b = v('vd2', 'lenvideo002', 0, dur: 11.5);
      expect(collapse([a, b]).$1.length, 2);
    });

    test('video vs picture -> never collapsed, even with identical thumbnails', () {
      final video = v('ve1', 'vidvsimg001', 0, dur: 8);
      final pic = post('ve2', img('picvsvideo1'));
      Dedupe.debugSetHash(pic.media.single.thumb, 0);
      final videoNoDur = v('ve3', 'vidvsimg002', 0);
      expect(collapse([video, pic]).$1.length, 2);
      expect(collapse([videoNoDur, pic]).$1.length, 2);
    });

    test('videos without a duration keep the strict picture distance', () {
      final a = v('vf1', 'nodur000001', 0);
      final close = v('vf2', 'nodur000002', 0x7); // 3 bits
      final loose = v('vf3', 'nodur000003', (1 << 10) - 1); // 10 bits
      expect(collapse([a, close]).$1.length, 1);
      expect(collapse([a, loose]).$1.length, 2);
    });

    test('RedGIFs id in two URL forms -> collapsed', () {
      final a = post('vg1', {'url': 'https://www.redgifs.com/watch/happyblueduck'});
      final b = post('vg2', {'url': 'https://v3.redgifs.com/watch/HappyBlueDuck#rel=user'});
      expect(Dedupe.exactKeys(a), contains('v:rg:happyblueduck'));
      expect(collapse([a, b]).$1.length, 1);
    });

    test('Imgur gifv without i. and the mp4 -> collapsed', () {
      final a = post('vh1', {'url': 'https://imgur.com/AbCdEfG.gifv'});
      final b = post('vh2', {'url': 'https://i.imgur.com/AbCdEfG.mp4'});
      expect(Dedupe.exactKeys(a), contains('v:im:AbCdEfG'));
      expect(collapse([a, b]).$1.length, 1);
    });

    test('frame grabbing tries Reddit small copies first', () {
      expect(Dedupe.frameSources('https://v.redd.it/abc123/CMAF_720.mp4?source=fallback'), [
        'https://v.redd.it/abc123/CMAF_220.mp4',
        'https://v.redd.it/abc123/DASH_220.mp4',
        'https://v.redd.it/abc123/CMAF_720.mp4?source=fallback',
      ]);
      expect(Dedupe.frameSources('https://i.imgur.com/AbCdEfG.mp4'), ['https://i.imgur.com/AbCdEfG.mp4']);
    });

    test('framesMatch needs 3 of 4 frames close', () {
      expect(Dedupe.framesMatch([0, 0, 0, 0], [1, 3, 7, far]), isTrue);
      expect(Dedupe.framesMatch([0, 0, 0, 0], [1, 3, far, far]), isFalse);
      expect(Dedupe.framesMatch([0, 0, 0, 0], [0, 0, 0]), isFalse);
    });

    test('3c: frame hashes catch a re-upload with a different poster, only when the setting is on', () {
      final a = v('vi1', 'framevid001', 0, dur: 40);
      final b = v('vi2', 'framevid002', far, dur: 40); // different poster frame
      Dedupe.debugSetFrames(Dedupe.frameUrl(a)!, const VideoFrames(40.1, [10, 20, 30, 40]));
      Dedupe.debugSetFrames(Dedupe.frameUrl(b)!, const VideoFrames(39.8, [11, 21, 31, far]));
      expect(collapse([a, b]).$1.length, 2);
      videoFrameHashing.value = true;
      expect(collapse([a, b]).$1.length, 1);
    });
  });
}
