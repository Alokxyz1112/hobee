import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Settings → Keep screen on.
enum AwakeMode { off, viewer, everywhere }

/// Decides whether the screen may time out. A playing video always keeps it on (as before). On top of that:
/// [AwakeMode.viewer] keeps it on while the viewer is open (pictures too), [AwakeMode.everywhere] while the app
/// is open. With an [idleMinutes] limit, the setting lets go after that long without a touch, so a phone left
/// on a picture still turns off; a playing video still keeps it on.
class ScreenAwake {
  static final mode = ValueNotifier<AwakeMode>(AwakeMode.off);
  static final idleMinutes = ValueNotifier<int>(0); // 0 = no limit
  static const idleChoices = [0, 5, 10, 15, 30];

  static int _viewers = 0;
  static bool _video = false;
  static DateTime? _touched;
  static Timer? _timer;
  static bool? _on;

  @visibleForTesting
  static Future<void> Function(bool on) apply = (on) => WakelockPlus.toggle(enable: on);
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    mode.value = AwakeMode.values[(sp.getInt('awakeMode') ?? 0).clamp(0, AwakeMode.values.length - 1)];
    idleMinutes.value = sp.getInt('awakeIdle') ?? 0;
    mode.addListener(() {
      sp.setInt('awakeMode', mode.value.index);
      touched();
    });
    idleMinutes.addListener(() {
      sp.setInt('awakeIdle', idleMinutes.value);
      touched();
    });
    touched();
  }

  static void viewerOpened() {
    _viewers++;
    touched();
  }

  static void viewerClosed() {
    if (_viewers > 0) _viewers--;
    check();
  }

  static void videoPlaying(bool playing) {
    _video = playing;
    check();
  }

  /// Any touch on the screen (from the app's root listener) restarts the idle limit.
  static void touched() {
    _touched = clock();
    check();
  }

  /// True when the setting (not a video) holds the screen on right now.
  static bool get _held {
    final m = mode.value;
    if (m == AwakeMode.off || (m == AwakeMode.viewer && _viewers == 0)) return false;
    final lim = idleMinutes.value;
    if (lim <= 0) return true;
    return clock().difference(_touched ?? clock()) < Duration(minutes: lim);
  }

  static bool get on => _video || _held;

  /// Re-evaluates and applies; also schedules the next idle check.
  @visibleForTesting
  static void check() {
    _timer?.cancel();
    final lim = idleMinutes.value;
    if (lim > 0 && mode.value != AwakeMode.off && _touched != null) {
      final left = _touched!.add(Duration(minutes: lim)).difference(clock());
      if (left > Duration.zero) _timer = Timer(left, check);
    }
    final want = on;
    if (want != _on) {
      _on = want;
      apply(want).catchError((_) {});
    }
  }

  @visibleForTesting
  static void debugReset() {
    _timer?.cancel();
    _viewers = 0;
    _video = false;
    _touched = null;
    _on = null;
    mode.value = AwakeMode.off;
    idleMinutes.value = 0;
  }
}
