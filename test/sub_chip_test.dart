import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/nav.dart';
import 'package:hobee/sub_search.dart';
import 'package:hobee/sub_users.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    deepSource.value = 'fol:1';
    deepReturn.value = null;
    mainTab.value = 0;
  });

  // The viewer is a pushed page; the chip closes it and switches to Deep Search.
  Future<void> openViewerWith(WidgetTester t, Widget chip) async {
    await t.pumpWidget(MaterialApp(home: Builder(
      builder: (c) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => Scaffold(backgroundColor: Colors.black, body: Center(child: chip)))),
          child: const Text('open'),
        ),
      ),
    )));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('subreddit chip opens that subreddit; Back returns to the Following list', (t) async {
    await openViewerWith(t, const SubChip('CosplayGirlsNSFW'));
    await t.tap(find.byKey(const Key('sub-chip')));
    await t.pumpAndSettle();
    expect(deepSource.value, subKey('CosplayGirlsNSFW'));
    expect(mainTab.value, 1);
    expect(deepReturn.value, 'fol:1');
    expect(find.text('open'), findsOneWidget, reason: 'the viewer page closed');
  });

  testWidgets("a user's profile space (u_name) opens the user", (t) async {
    await openViewerWith(t, const SubChip('u_asphyxiangel'));
    await t.tap(find.byKey(const Key('sub-chip')));
    await t.pumpAndSettle();
    expect(deepSource.value, 'deep:asphyxiangel');
    expect(deepReturn.value, 'fol:1', reason: 'Back returns to the Following list');
  });

  testWidgets('an invalid name does nothing', (t) async {
    await openViewerWith(t, const SubChip('bad name!'));
    await t.tap(find.byKey(const Key('sub-chip')));
    await t.pumpAndSettle();
    expect(deepSource.value, 'fol:1');
    expect(mainTab.value, 0);
  });
}
