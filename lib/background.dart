import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'following.dart';
import 'follows.dart';

/// Settings → Background refresh: keeps the active Following profile up to date while the app is closed,
/// using Android's WorkManager. Android picks the exact time (at least the chosen interval apart, later in
/// Doze), so this keeps lists fresh but isn't live. Off by default.
class BackgroundRefresh {
  static const task = 'hobees.following.refresh';
  static final enabled = ValueNotifier<bool>(false);
  static final wifiOnly = ValueNotifier<bool>(true);
  static final chargingOnly = ValueNotifier<bool>(false);
  static final everyMinutes = ValueNotifier<int>(60);
  static const choices = [30, 60, 120, 240];

  /// Longest a background run keeps fetching (WorkManager stops workers after about 10 minutes).
  static const maxRun = Duration(minutes: 8);

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    enabled.value = sp.getBool('bgRefresh') ?? false;
    wifiOnly.value = sp.getBool('bgWifiOnly') ?? true;
    chargingOnly.value = sp.getBool('bgCharging') ?? false;
    final m = sp.getInt('bgEvery') ?? 60;
    everyMinutes.value = choices.contains(m) ? m : 60;
    for (final (n, k) in [(enabled, 'bgRefresh'), (wifiOnly, 'bgWifiOnly'), (chargingOnly, 'bgCharging')]) {
      n.addListener(() => sp.setBool(k, n.value).then((_) => schedule()));
    }
    everyMinutes.addListener(() => sp.setInt('bgEvery', everyMinutes.value).then((_) => schedule()));
    await Workmanager().initialize(backgroundDispatcher);
    await schedule();
  }

  /// Registers (or replaces) the periodic task with the current settings, or cancels it when off.
  static Future<void> schedule() async {
    try {
      if (!enabled.value) {
        await Workmanager().cancelByUniqueName(task);
        return;
      }
      await Workmanager().registerPeriodicTask(
        task,
        task,
        frequency: Duration(minutes: everyMinutes.value),
        constraints: Constraints(
          networkType: wifiOnly.value ? NetworkType.unmetered : NetworkType.connected,
          requiresCharging: chargingOnly.value,
          requiresBatteryNotLow: true,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );
    } catch (e) {
      debugPrint('background refresh schedule failed: $e');
    }
  }

  /// One background pass: continue (or start) the active profile's refresh round for up to [maxRun].
  static Future<bool> run({DateTime Function() now = DateTime.now}) async {
    await FollowStore.load();
    final pid = FollowStore.active.value;
    if (pid == null) return true;
    final src = followingKey(pid);
    final end = now().add(maxRun);
    var first = true;
    while (now().isBefore(end)) {
      final n = await Following.fetchMore(src, fromStart: first);
      first = false;
      if (n < 0 || !Following.refreshing(src)) break;
    }
    return true;
  }
}

/// WorkManager entry point (runs in a background isolate, without the UI).
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    DartPluginRegistrant.ensureInitialized();
    try {
      return await BackgroundRefresh.run();
    } catch (e) {
      debugPrint('background refresh failed: $e');
      return true; // don't let WorkManager retry in a tight loop; the next period tries again
    }
  });
}
