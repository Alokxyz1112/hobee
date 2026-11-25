import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/download.dart';
import 'package:hobee/models.dart';
import 'package:hobee/saved.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  final calls = <MethodCall>[];
  const media = MethodChannel('hobee/media');

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('hobees_saved');
    SavedStore.baseDir = () async => tmp;
    await (await Db.db).delete('saved');
    calls.clear();
    saveTo.value = SaveTo.hobees;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(media, (c) async {
      calls.add(c);
      return switch (c.method) { 'sdk' => 34, 'save' => 'content://media/1', 'zip' => 'content://downloads/1', _ => null };
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(media, null);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<SavedItem> put(String ext, int at, {String kind = 'image', String sub = 's'}) async {
    final f = await SavedStore.newFile(ext);
    await f.writeAsBytes([1, 2, 3]);
    final it = SavedItem(path: f.path, kind: kind, postId: 'p$at', subreddit: sub, author: 'a', savedAt: at);
    final id = await SavedStore.add(it);
    return SavedItem.fromRow({...it.toRow(), 'id': id});
  }

  test('saved rows round-trip, newest saved first', () async {
    await put('jpg', 1);
    await put('mp4', 3, kind: 'video', sub: 'v');
    await put('png', 2);
    final all = await SavedStore.all();
    expect([for (final s in all) s.savedAt], [3, 2, 1]);
    expect(all.first.isVideo, isTrue);
    expect(all.first.subreddit, 'v');
    expect(all.first.ext, 'mp4');
    expect(await SavedStore.count(), 3);
  });

  test('files live in the private gallery folder', () async {
    final it = await put('jpg', 1);
    expect(it.path.startsWith('${tmp.path}${Platform.pathSeparator}gallery') || it.path.startsWith('${tmp.path}/gallery'), isTrue);
    expect(isLocalPath(it.path) || Platform.isWindows, isTrue);
  });

  test('delete removes both the file and the row', () async {
    final a = await put('jpg', 1);
    final b = await put('jpg', 2);
    await SavedStore.remove([a]);
    expect(await File(a.path).exists(), isFalse);
    expect(await File(b.path).exists(), isTrue);
    expect([for (final s in await SavedStore.all()) s.id], [b.id]);
  });

  test('a saved item shows in the viewer as a local file', () async {
    final it = await put('jpg', 1);
    expect(it.media.url, it.path);
    expect(it.media.thumb, it.path, reason: 'images use the file itself as the grid picture');
    expect(it.post.media.single.url, it.path);
  });

  group('save destination', () {
    final post = Post('abc', 'title', 'pics', 'amy', '/r/pics/comments/abc', 1700000000, const [], const {});
    final item = MediaItem(MediaType.image, 'https://i.redd.it/x.jpg', '', width: 10, height: 20);

    Future<File> temp() async {
      final f = File('${tmp.path}/dl.png');
      await f.writeAsBytes([9, 9, 9]);
      return f;
    }

    test('Hobees gallery (default): the file is copied into the private folder and a row added, nothing goes to MediaStore', () async {
      final out = await Downloader.store(await temp(), ext: 'png', mime: 'image/png', video: false, item: item, post: post, profile: 4);
      expect(calls.where((c) => c.method == 'save'), isEmpty);
      final all = await SavedStore.all();
      expect(all, hasLength(1));
      expect(all.single.path, out);
      expect(await File(out).readAsBytes(), [9, 9, 9]);
      expect(all.single.subreddit, 'pics');
      expect(all.single.author, 'amy');
      expect(all.single.permalink, '/r/pics/comments/abc');
      expect(all.single.profile, 4);
      expect(all.single.width, 10);
    });

    test('Phone gallery: saved through MediaStore with a timestamp name, no gallery row', () async {
      saveTo.value = SaveTo.phone;
      final out = await Downloader.store(await temp(), ext: 'png', mime: 'image/png', video: false, item: item, post: post);
      expect(out, 'content://media/1');
      final save = calls.singleWhere((c) => c.method == 'save');
      expect(save.arguments['mime'], 'image/png');
      expect(save.arguments['video'], false);
      expect(save.arguments['name'] as String, matches(RegExp(r'^\d{8}_\d{6}\.png$')));
      expect(await SavedStore.count(), 0);
    });
  });
}
