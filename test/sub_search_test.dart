import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/models.dart';
import 'package:hobee/sub_search.dart';

void main() {
  test('sub key round trip', () {
    final k = subKey('EarthView', q: 'lake view', author: 'bob');
    final p = subParts(k);
    expect(isSubSearch(k), true);
    expect(p.sub, 'EarthView');
    expect(p.q, 'lake view');
    expect(p.author, 'bob');
    expect(subParts('sr:pics').q, '');
  });

  test('adult posts dropped, sort', () {
    Post mk(String id, int score, int c, bool adult) => Post.fromJson({
          'id': id, 'title': 't', 'subreddit': 's', 'author': 'a', 'created_utc': 1700000000,
          'score': score, 'num_comments': c, 'over_18': adult, 'is_self': true, 'selftext': 'x',
        })!;
    expect(Post.fromJson({'id': 'x', 'title': 't', 'over_18': true}), null);
    final l = [mk('a', 5, 9, false), mk('b', 50, 1, false), mk('c', 20, 3, false)];
    expect(l.where(subOk).length, 3);
    srSort.value = SrSort.top;
    srSortList(l);
    expect(l.map((p) => p.id), ['b', 'c', 'a']);
    srSort.value = SrSort.comments;
    srSortList(l);
    expect(l.first.id, 'a');
    resetSubOptions();
  });
}
