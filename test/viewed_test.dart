import 'package:flutter_test/flutter_test.dart';
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
}
