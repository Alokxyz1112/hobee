import 'package:flutter/material.dart';
import 'app_lock.dart';
import 'follows.dart';

/// Covers the whole app while [AppLock.locked]. Put above the navigator (MaterialApp.builder).
class LockGate extends StatelessWidget {
  final Widget child;
  const LockGate({super.key, required this.child});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: AppLock.locked,
        builder: (_, locked, c) => Stack(children: [
          c!,
          if (locked) const Positioned.fill(child: LockScreen()),
        ]),
        child: child,
      );
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool device = false, pin = false, busy = false;
  String? msg;

  @override
  void initState() {
    super.initState();
    () async {
      final d = await AppLock.deviceSupported();
      if (!mounted) return;
      setState(() {
        device = d;
        pin = !d && AppLock.hasPin.value; // no phone lock: go straight to the PIN pad
      });
      if (d) _device(); // ask at once, like other locked apps
    }();
  }

  Future<void> _device() async {
    if (busy) return;
    setState(() {
      busy = true;
      msg = null;
    });
    final ok = await AppLock.unlockWithDevice();
    if (!mounted) return;
    setState(() {
      busy = false;
      if (!ok) msg = 'Not unlocked. Try again${AppLock.hasPin.value ? ' or use the app PIN' : ''}.';
    });
  }

  Future<bool> _pin(String p) async {
    final ok = await AppLock.unlockWithPin(p);
    if (!ok && mounted) {
      final w = AppLock.pinWait;
      setState(() => msg = w > 0 ? 'Too many tries. Wait $w s.' : 'Wrong PIN');
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      key: const Key('lock-screen'),
      color: cs.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_outline, size: 56, color: cs.primary),
              const SizedBox(height: 12),
              Text(AppLock.reason, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (pin)
                PinPad(key: const Key('lock-pinpad'), onDone: _pin)
              else if (device)
                FilledButton.icon(
                  key: const Key('lock-unlock'),
                  onPressed: busy ? null : _device,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Unlock'),
                ),
              if (msg != null) ...[
                const SizedBox(height: 12),
                Text(msg!, key: const Key('lock-msg'), style: TextStyle(color: cs.error), textAlign: TextAlign.center),
              ],
              const SizedBox(height: 12),
              if (device && AppLock.hasPin.value)
                TextButton(
                  key: const Key('lock-switch'),
                  onPressed: () => setState(() {
                    pin = !pin;
                    msg = null;
                  }),
                  child: Text(pin ? 'Use fingerprint, face or screen lock' : 'Use app PIN'),
                ),
              if (!device && !AppLock.hasPin.value)
                const Text('No screen lock on this phone and no app PIN. Set one up to unlock.', textAlign: TextAlign.center),
              if (AppLock.cancellable) TextButton(key: const Key('lock-cancel'), onPressed: AppLock.cancel, child: const Text('Cancel')),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Digits 0–9, delete and OK. [onDone] returns true to close (the pad clears itself otherwise).
class PinPad extends StatefulWidget {
  final Future<bool> Function(String pin) onDone;
  final int min, max;
  const PinPad({super.key, required this.onDone, this.min = 4, this.max = 8});
  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String v = '';

  Future<void> _ok() async {
    if (v.length < widget.min) return;
    final p = v;
    final ok = await widget.onDone(p);
    if (!ok && mounted) setState(() => v = '');
  }

  Widget _key(String label, VoidCallback? f, {Key? key, IconData? icon}) => Padding(
        padding: const EdgeInsets.all(6),
        child: SizedBox(
          width: 72,
          height: 56,
          child: OutlinedButton(
            key: key,
            onPressed: f,
            style: OutlinedButton.styleFrom(shape: const StadiumBorder(), padding: EdgeInsets.zero),
            child: icon != null ? Icon(icon) : Text(label, style: const TextStyle(fontSize: 22)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < (v.length < widget.min ? widget.min : v.length); i++)
          Container(
            margin: const EdgeInsets.all(6),
            width: 14,
            height: 14,
            decoration: BoxDecoration(shape: BoxShape.circle, color: i < v.length ? cs.primary : cs.outlineVariant),
          ),
      ]),
      const SizedBox(height: 12),
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
      ])
        Row(mainAxisSize: MainAxisSize.min, children: [
          for (final d in row) _key(d, v.length >= widget.max ? null : () => setState(() => v += d), key: Key('pin-$d')),
        ]),
      Row(mainAxisSize: MainAxisSize.min, children: [
        _key('', v.isEmpty ? null : () => setState(() => v = v.substring(0, v.length - 1)), key: const Key('pin-del'), icon: Icons.backspace_outlined),
        _key('0', v.length >= widget.max ? null : () => setState(() => v += '0'), key: const Key('pin-0')),
        _key('', v.length < widget.min ? null : _ok, key: const Key('pin-ok'), icon: Icons.check),
      ]),
    ]);
  }
}

/// Set or change the app PIN: enter it twice.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});
  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  String? first;
  String? msg;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('App PIN')),
        body: Center(
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(first == null ? 'Enter a PIN (4–8 digits)' : 'Enter it again', style: Theme.of(context).textTheme.titleMedium),
              if (msg != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(msg!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 16),
              PinPad(
                key: ValueKey(first == null ? 'pin-first' : 'pin-again'),
                onDone: (p) async {
                  if (first == null) {
                    setState(() {
                      first = p;
                      msg = null;
                    });
                    return true;
                  }
                  if (p != first) {
                    setState(() {
                      first = null;
                      msg = "The PINs didn't match. Start again.";
                    });
                    return false;
                  }
                  await AppLock.setPin(p);
                  if (context.mounted) Navigator.pop(context, true);
                  return true;
                },
              ),
            ]),
          ),
        ),
      );
}

/// Settings → App lock section.
class AppLockSettings extends StatefulWidget {
  const AppLockSettings({super.key});
  @override
  State<AppLockSettings> createState() => _AppLockSettingsState();
}

class _AppLockSettingsState extends State<AppLockSettings> {
  void _say(String s) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(s)));

  Future<void> _toggle(bool on) async {
    if (on) {
      if (!await AppLock.canUnlock()) {
        _say('Set a screen lock on the phone, or an app PIN below, first.');
        return;
      }
      AppLock.enabled.value = true;
    } else if (await AppLock.confirm('Unlock to turn the app lock off')) {
      AppLock.enabled.value = false;
    }
  }

  Future<void> _pin() async {
    if (AppLock.hasPin.value && !await AppLock.confirm('Unlock to change the app PIN')) return;
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const PinSetupScreen()));
  }

  Future<void> _removePin() async {
    if (!await AppLock.confirm('Unlock to remove the app PIN')) return;
    if (AppLock.enabled.value && !await AppLock.deviceSupported()) {
      _say("The phone has no screen lock, so the app PIN can't be removed while the app lock is on.");
      return;
    }
    await AppLock.removePin();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([AppLock.enabled, AppLock.afterSeconds, AppLock.hideRecents, AppLock.hasPin, AppLock.lockedProfiles]),
        builder: (_, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SwitchListTile(
            key: const Key('lock-enabled'),
            secondary: const Icon(Icons.lock_outline),
            title: const Text('App lock'),
            subtitle: const Text('Unlock with fingerprint, face or the phone\'s screen lock (or an app PIN) when Hobees opens.'),
            value: AppLock.enabled.value,
            onChanged: _toggle,
          ),
          if (AppLock.enabled.value)
            ListTile(
              contentPadding: const EdgeInsets.only(left: 72, right: 16),
              dense: true,
              title: const Text('Lock after leaving the app'),
              subtitle: const Text('Also locks when Keep screen on\'s idle limit is reached.'),
              trailing: DropdownButton<int>(
                key: const Key('lock-after'),
                value: AppLock.afterSeconds.value,
                items: [for (final s in AppLock.afterChoices) DropdownMenuItem(value: s, child: Text(s == 0 ? 'Immediately' : '${s ~/ 60} min'))],
                onChanged: (v) => AppLock.afterSeconds.value = v ?? 0,
              ),
            ),
          ListTile(
            key: const Key('lock-pin'),
            contentPadding: const EdgeInsets.only(left: 72, right: 16),
            dense: true,
            title: Text(AppLock.hasPin.value ? 'Change app PIN' : 'Set an app PIN'),
            subtitle: const Text('Optional. Works even without fingerprints or a phone screen lock.'),
            onTap: _pin,
            trailing: AppLock.hasPin.value ? TextButton(key: const Key('lock-pin-remove'), onPressed: _removePin, child: const Text('Remove')) : null,
          ),
          SwitchListTile(
            key: const Key('lock-recents'),
            contentPadding: const EdgeInsets.only(left: 72, right: 16),
            dense: true,
            title: const Text('Hide in recent apps'),
            subtitle: const Text('Blank preview in the app switcher. Also blocks screenshots and screen recording.'),
            value: AppLock.hideRecents.value,
            onChanged: (v) => AppLock.hideRecents.value = v,
          ),
          ListTile(
            key: const Key('lock-lists'),
            contentPadding: const EdgeInsets.only(left: 72, right: 16),
            dense: true,
            title: const Text('Locked lists'),
            subtitle: Text(AppLock.lockedProfiles.value.isEmpty
                ? 'None. Chosen Following lists ask for an unlock before opening, even with the app lock off.'
                : '${AppLock.lockedProfiles.value.length} locked. They ask for an unlock before opening, even with the app lock off.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LockedListsScreen())),
          ),
        ]),
      );
}

/// Pick the Following lists that need an unlock before opening.
class LockedListsScreen extends StatefulWidget {
  const LockedListsScreen({super.key});
  @override
  State<LockedListsScreen> createState() => _LockedListsScreenState();
}

class _LockedListsScreenState extends State<LockedListsScreen> {
  List<Profile> profiles = const [];

  @override
  void initState() {
    super.initState();
    FollowStore.profiles().then((p) => mounted ? setState(() => profiles = p) : null);
  }

  Future<void> _set(Profile p, bool lock) async {
    final s = {...AppLock.lockedProfiles.value};
    if (lock) {
      if (!await AppLock.canUnlock()) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('Set a screen lock on the phone, or an app PIN in Settings, first.')));
        return;
      }
      s.add(p.id);
    } else {
      if (!await AppLock.confirm('Unlock to stop locking ${p.name}')) return;
      s.remove(p.id);
    }
    AppLock.lockedProfiles.value = s;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Locked lists')),
        body: ValueListenableBuilder(
          valueListenable: AppLock.lockedProfiles,
          builder: (_, locked, _) => ListView(children: [
            for (final p in profiles)
              CheckboxListTile(
                key: ValueKey('lock-profile-${p.id}'),
                title: Text(p.name),
                value: locked.contains(p.id),
                onChanged: (v) => _set(p, v ?? false),
              ),
          ]),
        ),
      );
}
