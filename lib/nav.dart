import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Selected bottom-nav tab: 0 Home, 1 Deep Search, 2 Search, 3 Settings.
final mainTab = ValueNotifier<int>(0);

/// Active deep-search source ("deep:NAME" or "deep:NAME@SUB"), null = show the search form.
final deepSource = ValueNotifier<String?>(null);

/// Prefill for the Deep Search form (user, subreddit).
final deepPrefill = ValueNotifier<(String, String)?>(null);

final cleanUser = RegExp(r'^/?u(ser)?/');
final cleanSub = RegExp(r'^/?r/');
final validName = RegExp(r'^[A-Za-z0-9_-]{2,30}$');

/// Switch to the Deep Search tab. With [user], start that search right away.
void openDeepSearch({String? user, String? sub}) {
  if (user != null && validName.hasMatch(user)) {
    final s = (sub ?? '').trim();
    deepSource.value = 'deep:$user${s.isEmpty ? '' : '@$s'}';
    Recents.add(Recents.deep, deepSource.value!.substring(5));
  } else if (user == null) {
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
