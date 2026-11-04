import 'package:flutter/material.dart';

/// Bottom of a post list: loading, error with Retry, end of list, or more to fetch.
/// Never shows a bare "Load more" under an empty list.
class ListFooter extends StatelessWidget {
  final bool loading, done, empty, searching;
  final String? error;
  final Widget? doneChild;
  final VoidCallback onMore;
  const ListFooter({super.key, required this.loading, required this.done, required this.empty, required this.onMore,
      this.error, this.doneChild, this.searching = false});

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    Widget body;
    if (loading) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(key: Key('footer-loading')),
        if (empty) ...[
          const SizedBox(height: 12),
          Text(searching ? 'Searching posts...' : 'Loading...', style: muted, textAlign: TextAlign.center),
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
      body = doneChild ?? Text(empty ? 'Nothing here' : 'No more posts', style: muted, textAlign: TextAlign.center);
    } else if (empty) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(searching ? 'No matches in the posts checked so far.' : 'Nothing to show yet.', style: muted, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(key: const Key('footer-older'), onPressed: onMore, icon: const Icon(Icons.history_rounded),
            label: Text(searching ? 'Search older posts' : 'Try again')),
      ]);
    } else {
      body = TextButton(key: const Key('footer-more'), onPressed: onMore, child: const Text('Load more'));
    }
    return Padding(padding: const EdgeInsets.all(24), child: Center(child: body));
  }
}
