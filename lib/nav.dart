import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'accounts.dart';

/// Selected bottom-nav tab: 0 Home, 1 Deep Search, 2 Search, 3 Settings.
final mainTab = ValueNotifier<int>(0);

/// Active deep-search source ("deep:NAME" or "deep:NAME@SUB"), null = show the search form.
final deepSource = ValueNotifier<String?>(null);

/// Prefill for the Deep Search form (user, subreddit).
final deepPrefill = ValueNotifier<(String, String)?>(null);

/// Subreddit results to go back to after opening an author from them (kept alive, not reloaded).
final deepReturn = ValueNotifier<String?>(null);

/// The Following list (or subreddit results) a subreddit or profile was opened from, e.g. from the viewer's
/// chips. The back arrow returns there after [deepReturn].
final deepPrev = ValueNotifier<String?>(null);

/// Remember [from] as the place to go back to when leaving it for [to].
void rememberPrev(String? from, String to) {
  if (from != null && from != to && (from.startsWith('fol:') || from.startsWith('sr:'))) deepPrev.value = from;
}

/// Back to [deepPrev], if any. True when it went back.
bool backToPrev() {
  final p = deepPrev.value;
  if (p == null) return false;
  deepPrev.value = null;
  deepReturn.value = null;
  deepSource.value = p;
  return true;
}

/// Called right before leaving subreddit results for a profile (saves and clears post filters).
void Function(String user)? onLeaveSub;
final messengerKey = GlobalKey<ScaffoldMessengerState>();

final cleanUser = RegExp(r'^/?u(ser)?/');
final cleanSub = RegExp(r'^/?r/');
final validName = RegExp(r'^[A-Za-z0-9_-]{2,30}$');

/// Switch to the Deep Search tab. With [user], start that search right away.
void openDeepSearch({String? user, String? sub}) {
  if (user != null && validName.hasMatch(user)) {
    final s = (sub ?? '').trim();
    final cur = deepSource.value;
    final to = 'deep:$user${s.isEmpty ? '' : '@$s'}';
    if (cur != null && cur.startsWith('sr:')) {
      deepReturn.value = cur;
      onLeaveSub?.call(user);
    } else {
      rememberPrev(cur, to); // e.g. a profile opened from a Following list
    }
    deepSource.value = to;
    Recents.add(Recents.deep, deepSource.value!.substring(5));
    DeepHistory.touch(deepSource.value!.substring(5));
  } else if (user == null) {
    deepReturn.value = null;
    deepPrev.value = null;
    deepSource.value = null;
  }
  mainTab.value = 1;
}

class Recents {
  static const deep = 'recentDeep', search = 'recentSearch';
  static final changed = ValueNotifier<int>(0);
  static SharedPreferences? _sp;
  static Future<void> load() async => _sp = await SharedPreferences.getInstance();
  static List<String> get(String key) => _sp?.getStringList(key) ?? [];
  static void add(String key, String v) {
    final l = get(key)..remove(v)..insert(0, v);
    _sp?.setStringList(key, l.take(15).toList());
    changed.value++;
  }

  static void remove(String key, String v) {
    _sp?.setStringList(key, get(key)..remove(v));
    changed.value++;
  }

  static void clear(String key) {
    _sp?.remove(key);
    changed.value++;
  }
}
