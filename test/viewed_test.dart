import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/gallery.dart';
import 'package:hobee/viewed.dart';

void main() {
  test('hides viewed authors case-insensitively, only when on', () {
    final posts = ['Amy', 'bob', 'amy', 'cat'];
    expect(withoutViewed(posts, (a) => a, {'amy'}, true), ['bob', 'cat']);
    expect(withoutViewed(posts, (a) => a, {'amy'}, false), posts);
    expect(withoutViewed(posts, (a) => a, <String>{}, true), posts);
  });

  test('Viewed mark/unmark updates the set in memory', () {
    Viewed.mark('Zed');
    expect(Viewed.has('zed'), isTrue);
    expect(Viewed.lastMarked, 'Zed');
    Viewed.unmark('zed');
    expect(Viewed.has('Zed'), isFalse);
  });

  test('scroll anchors to the nearest remaining item', () {
    final ids = [for (var i = 0; i < 30; i++) 'p$i'];
    // Top item is about index 15; 6 posts above it hidden = 2 rows of 3.
    final kept = ids.toSet()..removeAll(['p0', 'p1', 'p2', 'p3', 'p4', 'p5']);
    expect(anchoredOffset(1000, 2000, ids, kept, 100, 3), 800);
    // Hidden posts below the anchor do not move it.
    final kept2 = ids.toSet()..removeAll(['p25', 'p26', 'p27']);
    expect(anchoredOffset(1000, 2000, ids, kept2, 100, 3), 1000);
  });
}
