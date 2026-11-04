import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/archive.dart';
import 'package:hobee/filters.dart';
import 'package:hobee/sub_search.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> row(String id, int t, {String title = 'cat', String text = '', String flair = ''}) =>
    {'id': id, 'title': title, 'selftext': text, 'subreddit': 'pics', 'author': 'amy', 'created_utc': t, 'link_flair_text': flair, 'is_self': true};

void main() {
  test('a full page keeps paging even when nothing on it matched', () {
    final rows = [for (var i = 0; i < 100; i++) row('p$i', 2000 - i, title: 'dog')];
    final out = Archive.localKeywordPage(rows, 'cat', 100);
    expect(out.length, 1);
    expect(out.single['_hobee_full'], isTrue);
    expect(out.single['_hobee_cursor'], 1901);
  });

  test('a short page has no marker, so the search can end', () {
    final out = Archive.withPageMarker([row('a', 10), row('b', 9)], 50);
    expect(out.length, 2);
    expect(out.any((r) => r.containsKey('_hobee_cursor')), isFalse);
    expect(Archive.withPageMarker([for (var i = 0; i < 50; i++) row('k$i', 100 - i)], 50).last['_hobee_full'], isTrue);
  });

  test('local matching looks at text and flair, ignores case', () {
    final rows = [row('a', 5, title: 'x', text: 'A CAT here'), row('b', 4, title: 'x', flair: 'Cat'), row('c', 3, title: 'dog')];
    expect(Archive.localKeywordPage(rows, 'cat', 100).map((r) => r['id']), ['a', 'b']);
  });

  test('keeps searching when nothing is shown, within limits', () {
    expect(keepSearching(shown: 0, pages: 5, spent: const Duration(seconds: 10)), isTrue);
    expect(keepSearching(shown: 0, pages: 40, spent: const Duration(seconds: 10)), isFalse);
    expect(keepSearching(shown: 0, pages: 3, spent: const Duration(seconds: 95)), isFalse);
    expect(keepSearching(shown: 10, pages: 3, spent: Duration.zero), isTrue);
    expect(keepSearching(shown: 30, pages: 3, spent: Duration.zero), isFalse);
  });

  test('typed words can search the whole subreddit', () {
    expect(widerQuery('sr:pics', ' cat '), 'cat');
    expect(widerQuery('sr:pics?q=dog', 'cat'), isNull);
    expect(widerQuery('deep:amy', 'cat'), isNull);
  });

  test('one time reset of old saved filter values', () async {
    SharedPreferences.setMockInitialValues({'hideGone': true, 'hideDupesDeep': false, 'other': true});
    final sp = await SharedPreferences.getInstance();
    expect(await migrateOpenDefaults(sp), ['hideGone']);
    expect(sp.getBool('hideGone'), isNull);
    expect(sp.getBool('other'), isTrue);
    await sp.setBool('hideGone', true); // the user turns it back on later
    expect(await migrateOpenDefaults(sp), isEmpty);
    expect(sp.getBool('hideGone'), isTrue);
  });
}
