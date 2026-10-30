import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/models.dart';
import 'package:hobee/sub_users.dart';

Post mk(String id, String a, int t, ) => Post.fromJson({
      'id': id, 'title': 't', 'subreddit': 's', 'author': a, 'created_utc': t, 'score': 1,
      'num_comments': 0, 'over_18': false, 'is_self': true, 'selftext': 'x',
    })!;

void main() {
  final posts = [mk('1', 'amy', 100), mk('2', 'amy', 300), mk('3', 'bob', 200), mk('4', '[deleted]', 50), mk('5', 'AutoModerator', 60)];
  test('groups authors, skips deleted and automod', () {
    final g = groupAuthors(posts);
    expect(g.map((u) => u.name).toSet(), {'amy', 'bob'});
    expect(g.firstWhere((u) => u.name == 'amy').posts, 2);
  });
  test('drops adult profiles and sorts', () {
    final g = groupAuthors(posts);
    expect(filterUsers(g, const UserFilters(), (_) => null).first.name, 'amy');
    expect(filterUsers(g, const UserFilters(), (_) => null, adult: (n) => n == 'bob').map((u) => u.name), ['amy']);
    final k = {'amy': 5, 'bob': 50000};
    expect(filterUsers(g, const UserFilters(sort: UserSort.karma), (n) => k[n]).first.name, 'bob');
    expect(filterUsers(g, const UserFilters(sort: UserSort.latest), (_) => null).first.name, 'amy');
  });
}
