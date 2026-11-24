import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/db.dart';
import 'package:hobee/follows.dart';
import 'package:hobee/follows_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

List<String> labels(String text) => parseFollowList(text).follows.map((f) => f.label).toList();

void main() {
  group('parser', () {
    test('r/ and u/ forms, with and without leading slash, /user/', () {
      expect(labels('r/pics /r/aww u/spez /u/kn0thing /user/Some_One'), ['r/pics', 'r/aww', 'u/spez', 'u/kn0thing', 'u/Some_One']);
    });

    test('comma, semicolon, space and newline separated', () {
      expect(labels('r/a1,r/b2; r/c3\nr/d4\r\nr/e5'), ['r/a1', 'r/b2', 'r/c3', 'r/d4', 'r/e5']);
    });

    test('reddit and old.reddit URLs, trailing slash and query ignored', () {
      expect(
          labels('https://www.reddit.com/r/EarthPorn/ https://old.reddit.com/user/spez/submitted/?sort=new '
              'reddit.com/u/kn0thing np.reddit.com/r/pics?x=1#top'),
          ['r/EarthPorn', 'u/spez', 'u/kn0thing', 'r/pics']);
    });

    test('multireddit link with u_ entries and hyphenated usernames', () {
      final r = parseFollowList('https://old.reddit.com/r/pics+aww+u_some-user+EarthPorn+u_Other_Name+oddlysatisfying/');
      expect(r.follows.map((f) => f.label), ['r/pics', 'r/aww', 'u/some-user', 'r/EarthPorn', 'u/Other_Name', 'r/oddlysatisfying']);
      expect(r.subs, 4);
      expect(r.users, 2);
    });

    test('a 300+ name multireddit link', () {
      final names = [for (var i = 0; i < 260; i++) 'sub$i', for (var i = 0; i < 60; i++) 'u_user-$i'];
      final r = parseFollowList('https://old.reddit.com/r/${names.join('+')}/');
      expect(r.subs, 260);
      expect(r.users, 60);
      expect(r.skipped, isEmpty);
    });

    test('dedupes case-insensitively, keeping the first spelling', () {
      expect(labels('r/Pics r/pics /r/PICS u/Spez u/spez u_SPEZ'), ['r/Pics', 'u/Spez']);
    });

    test('bare names are subreddits; u_ bare names are users', () {
      expect(labels('pics aww u_spez'), ['r/pics', 'r/aww', 'u/spez']);
    });

    test('CSV with a subreddit column (Reddit data export)', () {
      const csv = 'id,subreddit\n2qh0u,pics\n2qh1o,"aww"\nabc,u_some-user\n';
      expect(labels(csv), ['r/pics', 'r/aww', 'u/some-user']);
    });

    test('junk is reported, not imported', () {
      final r = parseFollowList('r/ok_name https://www.reddit.com/r/pics/comments/abc/title/ r/x !!! r/way_too_long_subreddit_name_here');
      expect(r.follows.map((f) => f.label), ['r/ok_name', 'r/pics']);
      expect(r.skipped, containsAll(['x', 'way_too_long_subreddit_name_here']));
    });

    test('export as text and CSV', () {
      final fs = const [Follow(FollowKind.sub, 'pics'), Follow(FollowKind.user, 'spez')];
      expect(exportFollows(fs), 'r/pics\nu/spez');
      expect(exportFollows(fs, csv: true), 'kind,name\nsubreddit,pics\nuser,spez');
      expect(labels(exportFollows(fs)), ['r/pics', 'u/spez']); // round-trips
    });
  });

  group('store', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      final d = await Db.db;
      await d.delete('follows');
      await d.delete('profiles');
    });

    test('a Main profile is created on first use', () async {
      final ps = await FollowStore.profiles();
      expect(ps.map((p) => p.name), ['Main']);
      await FollowStore.load();
      expect(FollowStore.active.value, ps.first.id);
    });

    test('add skips duplicates case-insensitively; profiles stay separate', () async {
      final main = (await FollowStore.profiles()).first.id;
      final art = await FollowStore.createProfile('Art');
      final a = parseFollowList('r/pics r/aww u/spez').follows;
      expect(await FollowStore.add(main, a), 3);
      expect(await FollowStore.add(main, parseFollowList('r/PICS r/new_one').follows), 1);
      expect(await FollowStore.add(art, parseFollowList('r/EarthPorn').follows), 1);
      expect((await FollowStore.follows(main)).map((f) => f.label), ['r/aww', 'r/new_one', 'r/pics', 'u/spez']);
      expect((await FollowStore.follows(art)).map((f) => f.label), ['r/EarthPorn']);
    });

    test('remove and delete profile only touch that profile', () async {
      final ps = await FollowStore.profiles();
      final main = ps.first.id, art = ps.last.id;
      await FollowStore.remove(main, const Follow(FollowKind.sub, 'AWW'));
      expect((await FollowStore.follows(main)).map((f) => f.label), ['r/new_one', 'r/pics', 'u/spez']);
      expect(await FollowStore.deleteProfile(art), isTrue);
      expect(await FollowStore.follows(art), isEmpty);
      expect((await FollowStore.follows(main)).length, 3);
      expect(await FollowStore.deleteProfile(main), isFalse, reason: 'the last profile stays');
    });

    testWidgets('import screen: paste, preview counts, save into the profile', (t) async {
      final id = await t.runAsync(() async => (await FollowStore.profiles()).first.id);
      await t.pumpWidget(MaterialApp(
        home: Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ImportScreen(profile: id!))), child: const Text('go')))),
      ));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('import-text')), 'https://old.reddit.com/r/imp_a+imp_b+u_imp-user/ r/imp_a !!bad!!');
      await t.pump();
      expect(find.text('Found 2 subreddits and 1 users · 1 skipped'), findsOneWidget);
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 200))); // profiles load
      await t.pump();
      await t.tap(find.byKey(const Key('import-save')));
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
      await t.pumpAndSettle();
      final fs = await t.runAsync(() => FollowStore.follows(id!));
      expect(fs!.map((f) => f.label), containsAll(['r/imp_a', 'r/imp_b', 'u/imp-user']));
      expect(find.text('go'), findsOneWidget, reason: 'screen closes after saving');
    });

    test('rename profile', () async {
      final main = (await FollowStore.profiles()).first.id;
      await FollowStore.renameProfile(main, 'Everything');
      expect((await FollowStore.profiles()).first.name, 'Everything');
    });
  });
}
