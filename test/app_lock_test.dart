import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/app_lock.dart';
import 'package:hobee/app_lock_ui.dart';
import 'package:hobee/screen_awake.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MemPins extends PinStore {
  String? v;
  @override
  Future<String?> read() async => v;
  @override
  Future<void> write(String s) async => v = s;
  @override
  Future<void> delete() async => v = null;
}

void main() {
  late MemPins pins;
  late DateTime now;
  late bool deviceOk;
  late List<String> asked;
  late List<bool> secure;

  setUp(() {
    AppLock.debugReset();
    pins = MemPins();
    now = DateTime(2026, 11, 24, 12);
    deviceOk = true;
    asked = [];
    secure = [];
    AppLock.pinStore = pins;
    AppLock.clock = () => now;
    AppLock.deviceSupported = () async => true;
    AppLock.deviceAuth = (r) async {
      asked.add(r);
      return deviceOk;
    };
    AppLock.setSecure = (on) async => secure.add(on);
  });

  group('PIN hash', () {
    test('verifies the right PIN only, salted, never stores the PIN', () {
      final h = hashPin('2468', iterations: 1000);
      expect(h, startsWith('v1:1000:'));
      expect(h, isNot(contains('2468')));
      expect(verifyPin('2468', h), isTrue);
      expect(verifyPin('2469', h), isFalse);
      expect(verifyPin('', h), isFalse);
      expect(hashPin('2468', iterations: 1000), isNot(h), reason: 'random salt each time');
      expect(verifyPin('2468', 'garbage'), isFalse);
      expect(verifyPin('2468', 'v1:0:AAAA:AAAA'), isFalse);
    });

    test('five wrong PINs wait 30 s, then the right one works', () async {
      await AppLock.setPin('1357');
      AppLock.lock();
      for (var i = 0; i < 5; i++) {
        expect(await AppLock.unlockWithPin('0000'), isFalse);
      }
      expect(AppLock.pinWait, greaterThan(0));
      expect(await AppLock.unlockWithPin('1357'), isFalse, reason: 'still waiting');
      now = now.add(const Duration(seconds: 31));
      expect(await AppLock.unlockWithPin('1357'), isTrue);
      expect(AppLock.locked.value, isFalse);
    });
  });

  group('lock timer', () {
    test('locks on start when on; off by default', () async {
      SharedPreferences.setMockInitialValues({});
      await AppLock.load();
      expect(AppLock.enabled.value, isFalse);
      expect(AppLock.locked.value, isFalse);
      AppLock.debugReset();
      AppLock.pinStore = pins;
      AppLock.setSecure = (on) async => secure.add(on);
      SharedPreferences.setMockInitialValues({'lockEnabled': true, 'lockHideRecents': true, 'lockedProfiles': ['3', 'x']});
      await AppLock.load();
      expect(AppLock.locked.value, isTrue);
      expect(secure.last, isTrue, reason: 'hide in recent apps applied on start');
      expect(AppLock.lockedProfiles.value, {3});
    });

    test('locks after the chosen time away, not before', () {
      AppLock.enabled.value = true;
      AppLock.afterSeconds.value = 60;
      AppLock.paused();
      now = now.add(const Duration(seconds: 59));
      AppLock.resumed();
      expect(AppLock.locked.value, isFalse);
      AppLock.paused();
      now = now.add(const Duration(seconds: 60));
      AppLock.resumed();
      expect(AppLock.locked.value, isTrue);
    });

    test('immediately: any trip to the background locks', () {
      AppLock.enabled.value = true;
      AppLock.paused();
      AppLock.resumed();
      expect(AppLock.locked.value, isTrue);
    });

    test('lock off: nothing locks, except a locked list on screen', () {
      AppLock.paused();
      now = now.add(const Duration(minutes: 10));
      AppLock.resumed();
      expect(AppLock.locked.value, isFalse);
      AppLock.lockedProfiles.value = {7};
      AppLock.viewingProfile = () => 7;
      AppLock.paused();
      AppLock.resumed();
      expect(AppLock.locked.value, isTrue);
      expect(AppLock.cancellable, isFalse);
    });

    test("Keep screen on's idle limit locks the app", () {
      ScreenAwake.debugReset();
      ScreenAwake.apply = (_) async {};
      var t = DateTime(2026, 11, 24, 12);
      ScreenAwake.clock = () => t;
      ScreenAwake.onIdle = AppLock.idle;
      AppLock.enabled.value = true;
      ScreenAwake.mode.value = AwakeMode.everywhere;
      ScreenAwake.idleMinutes.value = 5;
      ScreenAwake.touched();
      expect(AppLock.locked.value, isFalse);
      t = t.add(const Duration(minutes: 6));
      ScreenAwake.check();
      expect(AppLock.locked.value, isTrue);
      ScreenAwake.debugReset();
    });
  });

  group('unlock', () {
    test('phone unlock opens; a failed one stays locked', () async {
      AppLock.lock();
      deviceOk = false;
      expect(await AppLock.unlockWithDevice(), isFalse);
      expect(AppLock.locked.value, isTrue);
      deviceOk = true;
      expect(await AppLock.unlockWithDevice(), isTrue);
      expect(AppLock.locked.value, isFalse);
      expect(asked.last, 'Unlock Hobees');
    });

    test('a locked list asks once until the app locks again; cancel keeps it closed', () async {
      AppLock.lockedProfiles.value = {2};
      expect(await AppLock.allowProfile(1, 'Main'), isTrue, reason: 'not locked');
      final f = AppLock.allowProfile(2, 'cscott0108b');
      expect(AppLock.locked.value, isTrue);
      expect(AppLock.reason, 'Unlock cscott0108b');
      AppLock.cancel();
      expect(await f, isFalse);
      final g = AppLock.allowProfile(2, 'cscott0108b');
      await AppLock.unlockWithDevice();
      expect(await g, isTrue);
      expect(await AppLock.allowProfile(2, 'cscott0108b'), isTrue, reason: 'already unlocked');
      AppLock.lock();
      await AppLock.unlockWithDevice();
      final h = AppLock.allowProfile(2, 'cscott0108b');
      expect(AppLock.locked.value, isTrue, reason: 'asks again after the app locked');
      AppLock.cancel();
      expect(await h, isFalse);
    });

    test('the app lock itself cannot be cancelled', () {
      AppLock.lock();
      AppLock.cancel();
      expect(AppLock.locked.value, isTrue);
    });
  });

  group('lock screen', () {
    Widget app() => MaterialApp(builder: (_, c) => LockGate(child: c!), home: const Scaffold(body: Text('content')));

    testWidgets('covers the app, asks the phone at once, opens on success', (t) async {
      deviceOk = false;
      await t.pumpWidget(app());
      AppLock.lock();
      await t.pumpAndSettle();
      expect(find.byKey(const Key('lock-screen')), findsOneWidget);
      expect(asked, ['Unlock Hobees'], reason: 'prompted on show');
      expect(find.byKey(const Key('lock-msg')), findsOneWidget);
      deviceOk = true;
      await t.tap(find.byKey(const Key('lock-unlock')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('lock-screen')), findsNothing);
      expect(find.text('content'), findsOneWidget);
    });

    testWidgets('app PIN on the pad: wrong clears, right opens', (t) async {
      AppLock.deviceSupported = () async => false; // no phone screen lock: straight to the pad
      await AppLock.setPin('2580');
      await t.pumpWidget(app());
      AppLock.lock();
      await t.pumpAndSettle();
      expect(find.byKey(const Key('lock-pinpad')), findsOneWidget);
      Future<void> type(String p) async {
        for (final d in p.split('')) {
          await t.tap(find.byKey(Key('pin-$d')));
          await t.pump();
        }
        await t.tap(find.byKey(const Key('pin-ok')));
        await t.pumpAndSettle();
      }

      await type('1111');
      expect(find.text('Wrong PIN'), findsOneWidget);
      await type('2580');
      expect(find.byKey(const Key('lock-screen')), findsNothing);
    });
  });
}
