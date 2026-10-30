import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/find.dart';
import 'package:hobee/models.dart';

Post p(Map<String, dynamic> x) =>
    Post.fromJson({'id': 'i', 'title': 't', 'subreddit': 's', 'author': 'a', 'permalink': '/p', 'created_utc': 0, ...x})!;

void main() {
  test('fold strips diacritics and case', () => expect(fold('Café ÉCLAIR'), 'cafe eclair'));
  test('terms keep quoted phrases', () => expect(queryTerms('red "blue sky" Zoë'), ['red', 'blue sky', 'zoe']));
  test('multi word AND and fuzzy', () {
    final post = p({'title': 'Sunset over the mountains', 'subreddit': 'EarthPorn'});
    expect(textMatches(post, queryTerms('sunset earthporn')), true);
    expect(textMatches(post, queryTerms('sunset beach')), false);
    expect(textMatches(post, queryTerms('mountians')), true);
  });
  test('one edit', () {
    expect(withinOneEdit('photo', 'phtoo'), isA<bool>());
    expect(withinOneEdit('photo', 'phot'), true);
    expect(withinOneEdit('photo', 'xyz'), false);
  });
  test('ranges', () => expect(matchRanges('Hello Café', ['cafe']), [(6, 10)]));
  test('docs and links', () {
    expect(isDocument(p({'url': 'https://x.com/a/report.pdf', 'is_self': false})), true);
    expect(isLink(p({'url': 'https://news.example.com/story', 'is_self': false})), true);
    expect(matchLabel(2), 'Exact');
    expect(matchLabel(8), 'Similar');
  });
}
