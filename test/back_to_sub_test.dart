import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/filters.dart';
import 'package:hobee/nav.dart';
import 'package:hobee/sub_users.dart';
import 'package:hobee/viewed.dart';

void main() {
  testWidgets('back from a profile restores filters without a seek and marks the author viewed', (t) async {
    await t.pumpWidget(MaterialApp(scaffoldMessengerKey: messengerKey, home: const Scaffold()));
    initSubNav();
    final range = DateTimeRange(start: DateTime(2024, 1, 1), end: DateTime(2024, 2, 1));
    dateRange.value = range;
    mediaFilter.value = MediaFilter.values.last;
    deepSource.value = 'sr:pics';
    // Leaving to a profile: what openDeepSearch does for an sr source.
    deepReturn.value = deepSource.value;
    onLeaveSub!('amy');
    deepSource.value = 'deep:amy';
    expect(dateRange.value, isNull); // profile starts clean
    expect(Viewed.has('amy'), isTrue);

    var seeksAllowed = 0;
    void l() { if (!restoringFilters && dateRange.value != null) seeksAllowed++; }
    dateRange.addListener(l);
    expect(backToSub(), isTrue);
    dateRange.removeListener(l);
    await t.pump();

    expect(deepSource.value, 'sr:pics');
    expect(deepReturn.value, isNull);
    expect(dateRange.value, range);
    expect(mediaFilter.value, MediaFilter.values.last);
    expect(seeksAllowed, 0, reason: 'date window restore must not start a fetch');
    expect(find.text('Undo'), findsOneWidget);
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    await t.tap(find.text('Undo'));
    expect(Viewed.has('amy'), isFalse);
  });
}
