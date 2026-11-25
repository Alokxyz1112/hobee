import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App PIN hash: PBKDF2-HMAC-SHA256 with a random 16-byte salt, stored as `v1:<iterations>:<salt>:<hash>`
/// (base64). The PIN itself is never stored.
String hashPin(String pin, {List<int>? salt, int iterations = 20000}) {
  final s = salt ?? List<int>.generate(16, (_) => Random.secure().nextInt(256));
  final h = _pbkdf2(utf8.encode(pin), s, iterations);
  return 'v1:$iterations:${base64Encode(s)}:${base64Encode(h)}';
}

bool verifyPin(String pin, String stored) {
  final p = stored.split(':');
  if (p.length != 4 || p[0] != 'v1') return false;
  final it = int.tryParse(p[1]);
  if (it == null || it < 1) return false;
  try {
    final want = base64Decode(p[3]);
    final got = _pbkdf2(utf8.encode(pin), base64Decode(p[2]), it);
    if (got.length != want.length) return false;
    var diff = 0;
    for (var i = 0; i < got.length; i++) {
      diff |= got[i] ^ want[i]; // same time whatever the first wrong byte
    }
    return diff == 0;
  } catch (_) {
    return false;
  }
}

List<int> _pbkdf2(List<int> password, List<int> salt, int iterations) {
  final mac = Hmac(sha256, password);
  var u = mac.convert([...salt, 0, 0, 0, 1]).bytes;
  final out = List<int>.of(u);
  for (var i = 1; i < iterations; i++) {
    u = mac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

/// Where the app PIN hash lives (Android Keystore-backed secure storage).
class PinStore {
  static const _key = 'appLockPin';
  final _s = const FlutterSecureStorage();
  Future<String?> read() => _s.read(key: _key);
  Future<void> write(String v) => _s.write(key: _key, value: v);
  Future<void> delete() => _s.delete(key: _key);
}

/// Settings → App lock (off by default).
///
/// Locks on app start and after [afterSeconds] in the background, and when Keep screen on's idle limit is
/// reached. Unlock with the phone's fingerprint/face or its PIN/pattern/password, or an optional app PIN.
/// Chosen Following lists ([lockedProfiles]) also ask before opening, even with the app lock off.
/// No lockout: the phone's own screen lock and the app PIN both always work; turning the lock off, removing the
/// PIN or unlocking a list first needs an unlock.
class AppLock {
  static final enabled = ValueNotifier<bool>(false);
  static final afterSeconds = ValueNotifier<int>(0);
  static const afterChoices = [0, 60, 300];
  static final hideRecents = ValueNotifier<bool>(false);
  static final lockedProfiles = ValueNotifier<Set<int>>(const {});
  static final hasPin = ValueNotifier<bool>(false);

  /// The lock screen shows while this is true.
  static final locked = ValueNotifier<bool>(false);
  static String reason = 'Unlock Hobees';
  /// True when the lock screen may be closed without unlocking (a list or a settings change asked, not the app).
  static bool cancellable = false;

  static DateTime? _leftAt;
  static final _openProfiles = <int>{};
  static Completer<bool>? _pending;
  static int _wrong = 0;
  static DateTime? _waitUntil;

  // Test seams.
  @visibleForTesting
  static Future<bool> Function(String reason) deviceAuth = _deviceAuth;
  /// Has the phone a screen lock / biometrics the unlock can use? (replaceable in tests)
  static Future<bool> Function() deviceSupported = _deviceSupported;
  @visibleForTesting
  static PinStore pinStore = PinStore();
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;
  @visibleForTesting
  static Future<void> Function(bool on) setSecure = _setSecure;
  /// The Following list shown right now, if any (set by the app).
  static int? Function() viewingProfile = () => null;

  static const _window = MethodChannel('hobee/window');

  static Future<bool> _deviceAuth(String reason) async {
    try {
      return await LocalAuthentication().authenticate(localizedReason: reason, biometricOnly: false, persistAcrossBackgrounding: true);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _deviceSupported() async {
    try {
      return await LocalAuthentication().isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  static Future<void> _setSecure(bool on) async {
    try {
      await _window.invokeMethod('secure', on);
    } catch (_) {}
  }

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    enabled.value = sp.getBool('lockEnabled') ?? false;
    final a = sp.getInt('lockAfter') ?? 0;
    afterSeconds.value = afterChoices.contains(a) ? a : 0;
    hideRecents.value = sp.getBool('lockHideRecents') ?? false;
    lockedProfiles.value = {for (final s in sp.getStringList('lockedProfiles') ?? const <String>[]) ?int.tryParse(s)};
    try {
      hasPin.value = await pinStore.read() != null;
    } catch (_) {
      hasPin.value = false;
    }
    enabled.addListener(() => sp.setBool('lockEnabled', enabled.value));
    afterSeconds.addListener(() => sp.setInt('lockAfter', afterSeconds.value));
    hideRecents.addListener(() {
      sp.setBool('lockHideRecents', hideRecents.value);
      setSecure(hideRecents.value);
    });
    lockedProfiles.addListener(() => sp.setStringList('lockedProfiles', [for (final p in lockedProfiles.value) '$p']));
    if (hideRecents.value) await setSecure(true);
    if (enabled.value) lock(); // locked on app start
  }

  /// Can an unlock happen at all? (phone screen lock or an app PIN)
  static Future<bool> canUnlock() async => hasPin.value || await deviceSupported();

  static void lock() {
    _openProfiles.clear();
    reason = 'Unlock Hobees';
    cancellable = false;
    locked.value = true;
  }

  /// App went to the background.
  static void paused() => _leftAt ??= clock();

  /// App came back: lock if it was away at least [afterSeconds].
  static void resumed() {
    final left = _leftAt;
    _leftAt = null;
    if (left == null || clock().difference(left).inSeconds < afterSeconds.value) return;
    if (enabled.value) {
      lock();
      return;
    }
    // App lock off: still cover a locked list that was on screen.
    final p = viewingProfile();
    _openProfiles.clear();
    if (p != null && lockedProfiles.value.contains(p)) {
      reason = 'Unlock this list';
      cancellable = false;
      locked.value = true;
    }
  }

  /// Keep screen on's idle limit was reached.
  static void idle() {
    if (enabled.value && !locked.value) lock();
  }

  static Future<bool> unlockWithDevice() async {
    final ok = await deviceAuth(reason);
    if (ok) _unlocked();
    return ok;
  }

  /// Seconds to wait before the next PIN try (after 5 wrong ones), 0 when free.
  static int get pinWait {
    final w = _waitUntil;
    if (w == null) return 0;
    final s = w.difference(clock()).inSeconds;
    return s > 0 ? s : 0;
  }

  static Future<bool> unlockWithPin(String pin) async {
    if (pinWait > 0) return false;
    final stored = await pinStore.read();
    if (stored != null && verifyPin(pin, stored)) {
      _wrong = 0;
      _waitUntil = null;
      _unlocked();
      return true;
    }
    if (++_wrong >= 5) {
      _wrong = 0;
      _waitUntil = clock().add(const Duration(seconds: 30));
    }
    return false;
  }

  static void _unlocked() {
    final p = viewingProfile();
    if (p != null) _openProfiles.add(p);
    locked.value = false;
    final c = _pending;
    _pending = null;
    c?.complete(true);
  }

  /// The lock screen's Cancel (only when [cancellable]).
  static void cancel() {
    if (!cancellable) return;
    locked.value = false;
    final c = _pending;
    _pending = null;
    c?.complete(false);
  }

  /// Ask for an unlock for [why] (turning the lock off, removing the PIN, …). False when cancelled.
  static Future<bool> confirm(String why) {
    _pending?.complete(false);
    final c = _pending = Completer<bool>();
    reason = why;
    cancellable = true;
    locked.value = true;
    return c.future;
  }

  /// Before opening Following list [id]: true at once unless it's locked and not unlocked since the last lock.
  static Future<bool> allowProfile(int id, String name) async {
    if (!lockedProfiles.value.contains(id) || _openProfiles.contains(id)) return true;
    final ok = await confirm('Unlock $name');
    if (ok) _openProfiles.add(id);
    return ok;
  }

  static Future<void> setPin(String pin) async {
    await pinStore.write(hashPin(pin));
    hasPin.value = true;
  }

  static Future<void> removePin() async {
    await pinStore.delete();
    hasPin.value = false;
  }

  @visibleForTesting
  static void debugReset() {
    enabled.value = false;
    afterSeconds.value = 0;
    hideRecents.value = false;
    lockedProfiles.value = const {};
    hasPin.value = false;
    locked.value = false;
    reason = 'Unlock Hobees';
    cancellable = false;
    _leftAt = null;
    _openProfiles.clear();
    _pending = null;
    _wrong = 0;
    _waitUntil = null;
    viewingProfile = () => null;
  }
}
