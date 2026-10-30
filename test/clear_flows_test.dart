import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/filters.dart';
import 'package:hobee/main.dart';
import 'package:hobee/models.dart';
import 'package:hobee/nav.dart';
import 'package:hobee/sub_search.dart';
import 'package:hobee/sub_users.dart';
import 'package:hobee/viewed.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Post mk(int i, String a) => Post.fromJson({
      'id': 'p$i', 'title': 'post $i singer', 'subreddit': 'pics', 'author': a, 'created_utc': 1700000000 - i * 3600,
      'score': i, 'num_comments': 0, 'over_18': false, 'is_self': true, 'selftext': 'body $i', 'permalink': '/r/pics/comments/p$i/',
    })!;

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final errors = <Object>[];

  Future<void> boot(WidgetTester t) async {
    SharedPreferences.setMockInitialValues({});
    FlutterError.onError = (d) => errors.add(d.exception);
    await t.runAsync(() async {
      await loadFilterPrefs();
      await SubHistory.load();
      initSubNav();
      await Viewed.load();
    });
    await t.pumpWidget(const HobeeApp());
    await t.pump(const Duration(milliseconds: 300));
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
      await t.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('clearing everything in subreddit search, users and profile flows never throws', (t) async {
    await t.runAsync(() async {
      final src = subKey('pics');
      await Db.savePosts(src, [for (var i = 0; i < 40; i++) mk(i, 'user${i % 6}')]);
      await Db.setCursor(src, null);
    });
    await boot(t);
    openSubSearch('pics');
    await settle(t);
    // Instant search, then clear it.
    searchQuery.value = 'singer';
    await settle(t);
    searchQuery.value = '';
    await settle(t);
    // Users tab, filters, then clear each.
    subView.value = 1;
    await settle(t);
    userFilters.value = userFilters.value.copy(sort: UserSort.karma);
    await settle(t);
    userFilters.value = const UserFilters();
    await settle(t);
    subView.value = 0;
    await settle(t);
    // Open a profile, come back, undo, clear viewed, clear history.
    openDeepSearch(user: 'user1');
    await settle(t);
    expect(backToSub(), isTrue);
    await settle(t);
    Viewed.clear();
    await settle(t);
    SubHistory.clear();
    await settle(t);
    // Clear the sub query chips, then reset to the form.
    openSubSearch('pics', q: 'singer');
    await settle(t);
    openSubSearch('pics');
    await settle(t);
    clearFilters();
    resetSubOptions();
    openDeepSearch();
    await settle(t);
    mainTab.value = 0;
    await settle(t);
    mainTab.value = 1;
    await settle(t);
    expect(errors, isEmpty, reason: errors.join('\n'));
    expect(t.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('clearing with empty data and corrupt saved filters never throws', (t) async {
    SharedPreferences.setMockInitialValues({'filters.main': '{"m":99,"q":5,"st":[9,"a"],"d":[5,"x"]}', 'filters.sub': '[1,2]', 'filters.deep': 'not json'});
    await t.runAsync(() async {
      await loadFilterPrefs();
      await resetSearchState();
      Viewed.clear();
      SubHistory.clear();
    });
    expect(searchQuery.value, '');
    expect(dateRange.value, isNull);
    await t.pumpWidget(const HobeeApp());
    openSubSearch('emptysub');
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
      await t.pump(const Duration(milliseconds: 200));
    }
    searchQuery.value = 'x';
    await t.pump(const Duration(milliseconds: 300));
    searchQuery.value = '';
    subView.value = 1;
    await t.pump(const Duration(milliseconds: 300));
    userFilters.value = const UserFilters();
    subView.value = 0;
    clearFilters();
    openDeepSearch();
    await t.pump(const Duration(milliseconds: 300));
    expect(t.takeException(), isNull);
  });
}
