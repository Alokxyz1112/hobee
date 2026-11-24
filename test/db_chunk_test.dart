import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Post post(String id, int created, {Map<String, dynamic> extra = const {}}) => Post.fromJson({
      'id': id, 'title': 't', 'subreddit': 's', 'author': 'a', 'permalink': '/p', 'created_utc': created,
      'url': 'https://i.redd.it/$id.jpg', 'post_hint': 'image', ...extra,
    })!;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await (await Db.db).delete('posts');
    Db.chunkRows = 2;
  });

  tearDown(() => Db.chunkRows = 1000);

  test('load reads in chunks and returns every post newest first', () async {
    await Db.savePosts('src', [post('a', 5), post('b', 9), post('c', 1), post('d', 7), post('e', 3)]);
    await Db.savePosts('other', [post('x', 100)]);
    final ps = await Db.load('src');
    expect([for (final p in ps) p.id], ['b', 'd', 'a', 'e', 'c']);
  });

  test('loadEverything returns each post once across sources', () async {
    await Db.savePosts('s1', [post('a', 1), post('b', 2), post('c', 3)]);
    await Db.savePosts('s2', [post('b', 2), post('d', 4)]);
    final ps = await Db.loadEverything();
    expect([for (final p in ps) p.id], ['d', 'c', 'b', 'a']);
  });

  test('live and thin ids are found without reading every post into memory', () async {
    await Db.savePosts('src', [
      post('a', 1, extra: {'_hobee_live': true}),
      post('b', 2, extra: {'_hobee_thin': true}),
      post('c', 3),
    ]);
    expect(await Db.liveIds('src'), {'a'});
    expect(await Db.thinIds('src'), {'b'});
  });
}
