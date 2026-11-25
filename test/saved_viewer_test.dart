import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/clean_image.dart';
import 'package:hobee/player.dart';
import 'package:hobee/saved.dart';
import 'package:hobee/viewer.dart';
import 'package:photo_view/photo_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const img = SavedItem(path: '/data/gallery/1_0.png', kind: 'image', subreddit: 'pics', author: 'amy', savedAt: 1);
  const vid = SavedItem(path: '/data/gallery/2_0.mp4', kind: 'video', thumb: '/data/gallery/2_0_t.jpg', savedAt: 2);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('saved pictures load from the file, capped like web pictures', () {
    final p = viewerProvider(img.path, 2000) as ResizeImage;
    expect(p.imageProvider, isA<FileImage>());
    expect((p.imageProvider as FileImage).file.path, img.path);
    expect(p.width, 2000);
    expect((gridThumbProvider(vid.thumb!) as ResizeImage).imageProvider, isA<FileImage>());
  });

  test('the photo fallback chain keeps a saved file', () {
    expect(withRedditOriginals([img.path, 'not a url']), [img.path]);
  });

  test('saved videos play from their file only', () async {
    expect(await videoSources(vid.media), [(vid.path, false)]);
  });

  testWidgets('a saved picture opens in the zoomable viewer with the gallery buttons', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Viewer(
        entries: [Entry(img.post, img.media, 0)],
        start: 0,
        local: true,
        actions: (_, _) => [IconButton(key: const Key('gallery-share'), icon: const Icon(Icons.share), onPressed: () {})],
      ),
    ));
    await t.pump();
    expect(find.byType(PhotoView), findsOneWidget, reason: 'pinch and double-tap zoom come from PhotoView');
    expect(find.byKey(const Key('gallery-share')), findsOneWidget);
    expect(find.byTooltip('Download'), findsNothing, reason: 'saved items show the gallery buttons instead');
    expect(find.text('r/pics'), findsOneWidget, reason: 'the subreddit chip still shows');
    await t.pumpWidget(const SizedBox());
  });
}
