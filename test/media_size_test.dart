import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/models.dart';

Map<String, dynamic> _post(Map<String, dynamic> extra) => {
      'id': 'abc',
      'title': 't',
      'subreddit': 's',
      'author': 'a',
      'permalink': '/r/s/comments/abc',
      'created_utc': 1700000000,
      ...extra,
    };

void main() {
  test('single image: size from preview source', () {
    final p = Post.fromJson(_post({
      'url': 'https://i.redd.it/abcdefghij12.jpg',
      'post_hint': 'image',
      'preview': {
        'images': [
          {
            'source': {'url': 'https://preview.redd.it/abcdefghij12.jpg?width=1080&amp;s=x', 'width': 1080, 'height': 1920},
            'resolutions': [],
          }
        ]
      },
    }))!;
    expect(p.media.single.width, 1080);
    expect(p.media.single.height, 1920);
    expect(p.media.single.aspect, closeTo(0.5625, 1e-9));
  });

  test('gallery: per-item size from media_metadata s.x / s.y', () {
    final p = Post.fromJson(_post({
      'is_gallery': true,
      'gallery_data': {
        'items': [
          {'media_id': 'aaaaaaaaaaa1'},
          {'media_id': 'bbbbbbbbbbb2'},
        ]
      },
      'media_metadata': {
        'aaaaaaaaaaa1': {'status': 'valid', 'e': 'Image', 'm': 'image/jpg', 's': {'u': 'https://preview.redd.it/aaaaaaaaaaa1.jpg?s=1', 'x': 800, 'y': 600}, 'p': []},
        'bbbbbbbbbbb2': {'status': 'valid', 'e': 'Image', 'm': 'image/png', 's': {'u': 'https://preview.redd.it/bbbbbbbbbbb2.png?s=2', 'x': 500, 'y': 1500}, 'p': []},
      },
    }))!;
    expect(p.media.length, 2);
    expect([p.media[0].width, p.media[0].height], [800, 600]);
    expect([p.media[1].width, p.media[1].height], [500, 1500]);
  });

  test('reddit video: size from reddit_video', () {
    final p = Post.fromJson(_post({
      'url': 'https://v.redd.it/xyz123',
      'secure_media': {
        'reddit_video': {'fallback_url': 'https://v.redd.it/xyz123/DASH_720.mp4', 'width': 720, 'height': 1280, 'duration': 12}
      },
    }))!;
    expect(p.media.single.type, MediaType.video);
    expect([p.media.single.width, p.media.single.height], [720, 1280]);
  });

  test('redgifs: size from oembed', () {
    final p = Post.fromJson(_post({
      'url': 'https://www.redgifs.com/watch/somegifname',
      'secure_media': {
        'type': 'redgifs.com',
        'oembed': {'thumbnail_url': 'https://thumbs.redgifs.com/x.jpg', 'width': 640, 'height': 360}
      },
    }))!;
    expect([p.media.single.width, p.media.single.height], [640, 360]);
  });

  test('crosspost: size from the parent post', () {
    final p = Post.fromJson(_post({
      'crosspost_parent_list': [
        {
          'url': 'https://i.redd.it/abcdefghij12.jpg',
          'post_hint': 'image',
          'preview': {
            'images': [
              {'source': {'url': 'https://preview.redd.it/abcdefghij12.jpg?s=x', 'width': 300, 'height': 200}, 'resolutions': []}
            ]
          },
        }
      ],
    }))!;
    expect([p.media.single.width, p.media.single.height], [300, 200]);
  });

  test('RSS/Redlib-shaped row without sizes: width/height stay null', () {
    final p = Post.fromJson(_post({
      'url': 'https://i.redd.it/abcdefghij12.jpg',
      'post_hint': 'image',
      'thumbnail': 'https://b.thumbs.redditmedia.com/t.jpg',
      'preview': {
        'images': [
          {'source': {'url': 'https://b.thumbs.redditmedia.com/t.jpg'}, 'resolutions': []}
        ]
      },
    }))!;
    expect(p.media.single.width, isNull);
    expect(p.media.single.aspect, isNull);
  });

  test('zero or bad sizes are ignored', () {
    expect(mediaSize({'preview': {'images': [{'source': {'width': 0, 'height': 100}}]}}), (null, null));
    expect(mediaSize({'preview': 'nope'}), (null, null));
    expect(mediaSize({}), (null, null));
  });
}
