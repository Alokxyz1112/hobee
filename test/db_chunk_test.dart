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

  test('slimPost keeps what the app reads and drops the rest', () {
    final d = {
      'id': 'a', 'title': 't', 'subreddit': 's', 'author': 'u', 'permalink': '/p', 'created_utc': 5, 'over_18': true,
      'url': 'https://i.redd.it/a.jpg', 'post_hint': 'image', 'selftext': 'x', '_hobee_live': true,
      'all_awardings': [1, 2, 3], 'retrieved_on': 9, 'author_flair_richtext': [],
      'crosspost_parent_list': [
        {'id': 'b', 'title': 'c', 'url': 'https://i.redd.it/b.jpg', 'treatment_tags': []}
      ],
    };
    final s = slimPost(d);
    expect(s.keys, isNot(contains('all_awardings')));
    expect(s.keys, isNot(contains('retrieved_on')));
    expect(s['_hobee_live'], isTrue);
    expect(s['over_18'], isTrue);
    expect((s['crosspost_parent_list'] as List).single, {'id': 'b', 'title': 'c', 'url': 'https://i.redd.it/b.jpg'});
    final a = Post.fromJson(d)!, b = Post.fromJson(s)!;
    expect(b.media.map((m) => m.url), a.media.map((m) => m.url));
  });

  test('loadPage pages newest first without gaps or repeats, ties included', () async {
    await Db.savePosts('src', [post('a', 5), post('b', 9), post('c', 5), post('d', 7), post('e', 5), post('f', 1)]);
    await Db.savePosts('other', [post('x', 100)]);
    final seen = <String>[];
    var page = await Db.loadPage('src', limit: 2);
    while (page.isNotEmpty) {
      seen.addAll(page.map((p) => p.id));
      page = await Db.loadPage('src', limit: 2, created: page.last.created, id: page.last.id);
    }
    expect(seen, ['b', 'd', 'e', 'c', 'a', 'f']);
  });

  test('window plan: small feeds whole, big ones 1000 at a time, search reads all', () {
    (WindowRead, int) plan(int count, {int shown = 0, bool same = false, bool needAll = false, bool grow = false}) =>
        Db.windowRead(count: count, shown: shown, sameWindow: same, needAll: needAll, grow: grow);
    Db.windowMin = 2000;
    Db.windowStep = 1000;
    expect(plan(1500), (WindowRead.all, 0));
    expect(plan(28000), (WindowRead.window, 1000), reason: 'opening a big feed');
    expect(plan(28000, shown: 3000, same: true), (WindowRead.window, 3000), reason: 'a reload keeps the window size');
    expect(plan(28000, shown: 3000, same: false), (WindowRead.window, 1000), reason: 'another feed starts small');
    expect(plan(28000, shown: 1000, same: true, grow: true), (WindowRead.next, 1000), reason: 'scrolling near the end');
    expect(plan(28000, shown: 1000, same: true, needAll: true), (WindowRead.all, 0), reason: 'search / date range');
  });
}
