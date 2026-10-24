import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/public_sources.dart';
import 'package:hobee/models.dart';
void main() {
  test('redlib parse', () {
    final p = Redlib.parse('https://redlib.ducks.party', File('/tmp/rl_redlib.ducks.party').readAsStringSync(), 'GallowBoob');
    final posts = p.rows.map(Post.fromJson).whereType<Post>().toList();
    final withMedia = posts.where((x) => x.media.isNotEmpty).length;
    // ignore: avoid_print
    print('redlib rows ${p.rows.length} media $withMedia next ${p.after} first ${posts.first.media.firstOrNull?.url} date ${posts[1].date}');
    expect(withMedia, greaterThan(5));
  });
  test('rss parse', () {
    final p = RedditRss.parse(File('/tmp/r.xml').readAsStringSync(), 'GallowBoob');
    final posts = p.rows.map(Post.fromJson).whereType<Post>().toList();
    final withMedia = posts.where((x) => x.media.isNotEmpty).length;
    // ignore: avoid_print
    print('rss rows ${p.rows.length} media $withMedia next ${p.after} ${posts[3].title} ${posts[3].subreddit} ${posts[3].date} ${posts[3].media.firstOrNull?.url}');
    expect(withMedia, greaterThan(50));
  });
}
