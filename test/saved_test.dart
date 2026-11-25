import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/saved.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('hobees_saved');
    SavedStore.baseDir = () async => tmp;
    await (await Db.db).delete('saved');
  });

  tearDown(() async {
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
}
