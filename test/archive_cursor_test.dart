import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/archive.dart';

void main() {
  test('full page cursor re-reads the oldest second so same-second posts are not skipped', () {
    final rows = [for (var i = 0; i < 100; i++) <String, dynamic>{'id': 'p$i', 'created_utc': 1000 + i}];
    expect(Archive.cursorOfForTest(rows), 1001);
  });
  test('short page ends paging', () {
    expect(Archive.cursorOfForTest([<String, dynamic>{'id': 'a', 'created_utc': 5}]), isNull);
  });
}
