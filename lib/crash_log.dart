import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'clean_image.dart' show isBenignImageError;

/// Local crash log: every uncaught Flutter, platform or zone error is appended to a file.
class CrashLog {
  static File? _f;
  static const _max = 200 * 1024;

  static Future<File> _file() async => _f ??= File('${(await getApplicationSupportDirectory()).path}/crash.log');

  static Future<void> init() async {
    FlutterError.onError = (d) {
      // Never fatal. Expected image errors (deleted media, scrolled-away tiles) are not logged at all.
      if (d.silent || isBenignImageError(d.exception)) return;
      FlutterError.presentError(d);
      record(d.exception, d.stack, 'flutter');
    };
    PlatformDispatcher.instance.onError = (e, s) {
      record(e, s, 'platform');
      return true;
    };
    await _file();
  }

  /// Synchronous so the entry is on disk even if the process dies right after.
  static void record(Object e, StackTrace? s, [String kind = 'zone']) {
    if (isBenignImageError(e)) return;
    try {
      final f = _f;
      if (f == null) return;
      if (f.existsSync() && f.lengthSync() > _max) {
        final old = f.readAsStringSync();
        f.writeAsStringSync(old.substring(old.length - _max ~/ 2), flush: true);
      }
      final st = (s ?? StackTrace.empty).toString().split('\n').take(25).join('\n');
      f.writeAsStringSync('[${DateTime.now().toIso8601String()}] $kind: $e\n$st\n\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static Future<String> read() async {
    final f = await _file();
    return await f.exists() ? await f.readAsString() : '';
  }

  static Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}

class CrashLogScreen extends StatefulWidget {
  const CrashLogScreen({super.key});
  @override
  State<CrashLogScreen> createState() => _CrashLogScreenState();
}

class _CrashLogScreenState extends State<CrashLogScreen> {
  String? text;
  @override
  void initState() {
    super.initState();
    CrashLog.read().then((t) => mounted ? setState(() => text = t) : null);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Crash log'), actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy',
            onPressed: text == null || text!.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: text!));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                  },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: () async {
              await CrashLog.clear();
              if (mounted) setState(() => text = '');
            },
          ),
        ]),
        body: text == null
            ? const Center(child: CircularProgressIndicator())
            : text!.isEmpty
                ? const Center(child: Text('No crashes logged. Nice.'))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(text!, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                  ),
      );
}
