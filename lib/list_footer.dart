import 'package:flutter/material.dart';

/// Bottom of a post list: loading, error with Retry, end of list, or more to fetch.
/// Never shows a bare "Load more" under an empty list.
class ListFooter extends StatelessWidget {
  final bool loading, done, empty, searching;
  final String? error;
  final Widget? doneChild;
  final VoidCallback onMore;
  /// How far back the search has looked, e.g. '2/11/2026'. Shown while searching.
  final String? checkedTo;
  /// Optional wider search (e.g. ask the archive for the words across the whole subreddit).
  final String? widerLabel;
  final VoidCallback? onWider;
  const ListFooter({super.key, required this.loading, required this.done, required this.empty, required this.onMore,
      this.error, this.doneChild, this.searching = false, this.checkedTo, this.widerLabel, this.onWider});

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final back = checkedTo == null ? '' : ' back to $checkedTo';
    Widget? wider() => onWider == null || widerLabel == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton.icon(key: const Key('footer-wider'), onPressed: onWider, icon: const Icon(Icons.travel_explore), label: Text(widerLabel!, textAlign: TextAlign.center)),
          );
    Widget body;
    if (loading) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(key: Key('footer-loading')),
        if (empty) ...[
          const SizedBox(height: 12),
          Text(searching ? (checkedTo == null ? 'Searching posts...' : 'Searching posts...$back') : 'Loading...', style: muted, textAlign: TextAlign.center),
        ],
      ]);
    } else if (error != null) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.cloud_off_rounded, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 8),
        Text(error!, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(key: const Key('footer-retry'), onPressed: onMore, icon: const Icon(Icons.refresh_rounded), label: const Text('Retry')),
      ]);
    } else if (done) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        doneChild ?? Text(empty ? (searching ? 'No matches anywhere in this subreddit.' : 'Nothing here') : 'No more posts', style: muted, textAlign: TextAlign.center),
        ?(empty ? wider() : null),
      ]);
    } else if (empty) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(searching ? 'No matches yet in the posts checked$back. Older posts may still have some.' : 'Nothing to show yet.',
            style: muted, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(key: const Key('footer-older'), onPressed: onMore, icon: const Icon(Icons.history_rounded),
            label: Text(searching ? 'Keep searching older posts' : 'Try again')),
        ?wider(),
      ]);
    } else {
      body = TextButton(key: const Key('footer-more'), onPressed: onMore, child: const Text('Load more'));
    }
    return Padding(padding: const EdgeInsets.all(24), child: Center(child: body));
  }
}
