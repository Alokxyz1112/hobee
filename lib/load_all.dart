import 'dart:async';

/// One page of a bulk load: how many posts it added and whether the source says it is finished.
typedef PageResult = ({int added, bool done});

/// Progress while loading every page.
class LoadAllProgress {
  final int pages, added, failures;
  final String? note;
  const LoadAllProgress({this.pages = 0, this.added = 0, this.failures = 0, this.note});
}

enum LoadAllEnd { finished, stopped, gaveUp, stalled, limit }

/// Loads pages one after another (never in parallel), backs off on errors, stops when asked, and never spins:
/// every step awaits real work or a delay, so the UI keeps drawing frames. Pure and testable.
class LoadAllRunner {
  final Future<PageResult> Function() fetch;
  final void Function(LoadAllProgress p)? onProgress;
  final Future<void> Function()? onRefresh; // reload the visible list; called every few pages, not every page
  final bool Function() stopped;
  final Future<void> Function(Duration d) wait;
  final int maxPages, maxFailures, maxEmptyPages, refreshEvery;
  final Duration gap, pageTimeout;

  LoadAllRunner({
    required this.fetch,
    required this.stopped,
    this.onProgress,
    this.onRefresh,
    Future<void> Function(Duration d)? wait,
    this.maxPages = 400,
    this.maxFailures = 4,
    this.maxEmptyPages = 8,
    this.refreshEvery = 3,
    this.gap = const Duration(milliseconds: 400),
    this.pageTimeout = const Duration(seconds: 150),
  }) : wait = wait ?? ((d) => Future<void>.delayed(d));

  static Duration backoff(int failures) => Duration(seconds: (5 * (1 << (failures - 1))).clamp(5, 60));

  Future<LoadAllEnd> run() async {
    var pages = 0, added = 0, fails = 0, empty = 0, sinceRefresh = 0;
    LoadAllEnd end = LoadAllEnd.limit;
    String? note;
    void report() => onProgress?.call(LoadAllProgress(pages: pages, added: added, failures: fails, note: note));
    while (true) {
      if (stopped()) { end = LoadAllEnd.stopped; break; }
      if (pages >= maxPages) { end = LoadAllEnd.limit; break; }
      PageResult r;
      try {
        r = await fetch().timeout(pageTimeout);
      } catch (e) {
        fails++;
        note = '$e'.replaceFirst('Exception: ', '');
        report();
        if (fails >= maxFailures) { end = LoadAllEnd.gaveUp; break; }
        await wait(backoff(fails));
        continue;
      }
      fails = 0;
      note = null;
      pages++;
      added += r.added < 0 ? 0 : r.added;
      empty = r.added > 0 ? 0 : empty + 1;
      sinceRefresh++;
      if (r.done) { end = LoadAllEnd.finished; break; }
      if (empty >= maxEmptyPages) { end = LoadAllEnd.stalled; break; }
      if (sinceRefresh >= refreshEvery && onRefresh != null) {
        sinceRefresh = 0;
        try { await onRefresh!(); } catch (_) {}
      }
      report();
      await wait(gap);
    }
    report();
    if (onRefresh != null) {
      try { await onRefresh!(); } catch (_) {}
    }
    return end;
  }
}
