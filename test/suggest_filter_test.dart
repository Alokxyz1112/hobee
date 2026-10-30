import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/accounts.dart';

AcctMeta k(int? total, {bool? adult, bool gone = false}) => AcctMeta(total, total, total, adult, gone, 0);

void main() {
  final s = Suggestion('bob', 1, 'r');
  test('no karma limits', () {
    expect(AccountMeta.passes(k(0), s), true);
    expect(AccountMeta.passes(k(5000000), s), true);
    expect(AccountMeta.passes(k(null), s), true);
  });
  test('adult and gone accounts never suggested', () {
    expect(AccountMeta.passes(k(5, adult: true), s), false);
    expect(AccountMeta.passes(k(5), Suggestion('x', 1, 'r', nsfwHint: true)), false);
    expect(AccountMeta.passes(k(null, gone: true), s), false);
  });
  test('format', () {
    expect(fmtKarma(12400), '12.4K');
    expect(fmtKarma(1499932), '1.5M');
    expect(fmtKarma(999), '999');
  });
}
