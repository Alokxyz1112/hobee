import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/relevance.dart';

RDoc d(String title, {String flair = '', String text = '', String link = '', String sub = 'music', String author = 'a', int t = 0}) =>
    RDoc([title, flair, text, link, sub], author, t, 0);

List<String> rank(List<RDoc> docs, String q) {
  final r = rankDocs(docs, parseQuery(q));
  final ids = r.keys.toList()..sort((a, b) => r[b]!.score.compareTo(r[a]!.score));
  return [for (final i in ids) docs[i].fields[0]];
}

void main() {
  test('parses phrases, boosts, excludes, OR and prefixes', () {
    final q = parseQuery('"Taylor Swift" singer^2 -remix live OR acoustic u/Bob r/Music');
    expect(q.author, 'bob');
    expect(q.sub, 'music');
    expect(q.terms.map((t) => t.text), ['taylor swift', 'singer', 'remix', 'live', 'acoustic']);
    expect(q.terms[1].weight, 2);
    expect(q.terms[2].neg, isTrue);
    expect(q.terms[3].group, q.terms[4].group);
    expect(q.terms[0].group, isNot(q.terms[1].group));
    expect(parseQuery(q.serialize()).serialize(), q.serialize());
  });

  test('title beats body, whole word beats partial', () {
    final docs = [d('random post', text: 'singer here'), d('Best singer ever'), d('singers night'), d('singersongwriter tag')];
    final r = rank(docs, 'singer');
    expect(r.first, 'Best singer ever');
    expect(r.indexOf('singers night'), lessThan(r.indexOf('singersongwriter tag')));
    expect(r.last, 'random post');
  });

  test('entity: adjacent names rank above scattered, accents and possessives fold', () {
    final docs = [d('Singh met Arijit later'), d("Arijit Singh's new song"), d('Árijit singh live')];
    final r = rank(docs, 'arijit singh');
    expect(r.length, 3);
    expect(r.last, 'Singh met Arijit later');
  });

  test('quoted phrase needs the words together', () {
    final docs = [d('taylor swift tour'), d('swift taylor tour')];
    expect(rank(docs, '"taylor swift"'), ['taylor swift tour']);
  });

  test('exclusion drops posts', () {
    final docs = [d('song remix'), d('song original')];
    expect(rank(docs, 'song -remix'), ['song original']);
  });

  test('one typo allowed for words over 4 letters only', () {
    expect(rank([d('great guitar solo')], 'guiter'), ['great guitar solo']);
    expect(rank([d('the cat sat')], 'cot'), isEmpty);
  });

  test('boost changes the order', () {
    final docs = [d('piano cover', text: 'violin'), d('violin cover', text: 'piano')];
    expect(rank(docs, 'piano violin').first, 'piano cover');
    expect(rank(docs, 'piano violin^4').first, 'violin cover');
  });

  test('OR matches either; AND needs all', () {
    final docs = [d('cats'), d('dogs'), d('cats and dogs')];
    expect(rank(docs, 'cat OR dog').length, 3);
    expect(rank(docs, 'cat dog'), ['cats and dogs']);
  });

  test('hyphen and joined forms match, author filter applies, why matched', () {
    final docs = [d('Spider-Man trailer', flair: 'Movie', author: 'xx'), d('spiderman figure', author: 'yy')];
    expect(rank(docs, 'spiderman').length, 2);
    expect(rank(docs, 'spider-man').length, 2);
    expect(rank(docs, 'spiderman u/yy'), ['spiderman figure']);
    final h = rankDocs(docs, parseQuery('movie'));
    expect(h[0]!.why, 'flair');
  });
}
