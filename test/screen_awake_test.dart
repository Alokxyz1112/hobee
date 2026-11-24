import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/player.dart';
import 'package:hobee/screen_awake.dart';

void main() {
  late List<bool> applied;
  late DateTime now;

  setUp(() {
    ScreenAwake.debugReset();
    applied = [];
    now = DateTime(2026, 11, 24, 12);
    ScreenAwake.clock = () => now;
    ScreenAwake.apply = (on) async => applied.add(on);
    ScreenAwake.check();
    applied.clear();
  });

  test('off: only a playing video keeps the screen on', () {
    ScreenAwake.viewerOpened();
    expect(ScreenAwake.on, isFalse);
    ScreenAwake.videoPlaying(true);
    expect(applied, [true]);
    ScreenAwake.videoPlaying(false);
    expect(applied, [true, false]);
  });

  test('while viewing: on while a viewer is open, pictures included', () {
    ScreenAwake.mode.value = AwakeMode.viewer;
    ScreenAwake.check();
    expect(ScreenAwake.on, isFalse, reason: 'no viewer open');
    ScreenAwake.viewerOpened();
    expect(applied.last, isTrue);
    ScreenAwake.viewerClosed();
    expect(applied.last, isFalse);
  });

  test('everywhere: on whenever the app is open', () {
    ScreenAwake.mode.value = AwakeMode.everywhere;
    ScreenAwake.check();
    expect(applied, [true]);
  });

  test('idle limit lets the screen turn off; a touch or a playing video holds it', () {
    ScreenAwake.mode.value = AwakeMode.everywhere;
    ScreenAwake.idleMinutes.value = 5;
    ScreenAwake.touched();
    expect(ScreenAwake.on, isTrue);
    now = now.add(const Duration(minutes: 4));
    ScreenAwake.check();
    expect(ScreenAwake.on, isTrue);
    now = now.add(const Duration(minutes: 2));
    ScreenAwake.check();
    expect(ScreenAwake.on, isFalse);
    expect(applied.last, isFalse);
    ScreenAwake.videoPlaying(true);
    expect(ScreenAwake.on, isTrue, reason: 'a playing video ignores the idle limit');
    ScreenAwake.videoPlaying(false);
    ScreenAwake.touched();
    expect(ScreenAwake.on, isTrue);
    expect(applied.last, isTrue);
  });

  test('applies only on change', () {
    ScreenAwake.mode.value = AwakeMode.everywhere;
    for (var i = 0; i < 5; i++) {
      ScreenAwake.touched();
    }
    expect(applied, [true]);
  });

  test('player end label: time left or total length', () {
    expect(endLabel(const Duration(seconds: 10), const Duration(seconds: 83), remaining: true), '-1:13');
    expect(endLabel(const Duration(seconds: 10), const Duration(seconds: 83), remaining: false), '1:23');
    expect(endLabel(const Duration(seconds: 90), const Duration(seconds: 83), remaining: true), '-0:00');
  });
}
