import 'package:flutter/material.dart';

final currentSource = ValueNotifier<String>('submitted');

class SourceBar extends StatelessWidget {
  const SourceBar({super.key});

  static Future<void> pickSub(BuildContext context) async {
    final c = TextEditingController();
    final s = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Browse subreddit'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(prefixText: 'r/', hintText: 'pics')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Open')),
        ],
      ),
    );
    if (s != null && s.isNotEmpty) currentSource.value = 'r/${s.replaceFirst(RegExp(r'^/?r/'), '')}';
  }

  static Future<void> pickUser(BuildContext context) async {
    final c = TextEditingController();
    final s = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go to user'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(prefixText: 'u/', hintText: 'username')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Open')),
        ],
      ),
    );
    if (s != null && s.isNotEmpty) currentSource.value = 'u/${s.replaceFirst(RegExp(r'^/?u(ser)?/'), '')}';
  }

  static Future<void> pickDeep(BuildContext context) async {
    final c = TextEditingController(), sc = TextEditingController();
    final cur = currentSource.value;
    if (cur.startsWith('deep:')) {
      final s = cur.substring(5).split('@');
      c.text = s[0];
      if (s.length > 1) sc.text = s[1];
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Deep profile'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Look up a user\'s older and deleted posts from public archives (PullPush, Arctic Shift).', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          TextField(controller: c, autofocus: true, decoration: const InputDecoration(prefixText: 'u/', hintText: 'username')),
          TextField(controller: sc, decoration: const InputDecoration(prefixText: 'r/', hintText: 'subreddit (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Search archives')),
        ],
      ),
    );
    final u = c.text.trim().replaceFirst(RegExp(r'^/?u(ser)?/'), '');
    final s = sc.text.trim().replaceFirst(RegExp(r'^/?r/'), '');
    if (ok == true && RegExp(r'^[A-Za-z0-9_-]{2,30}$').hasMatch(u)) {
      currentSource.value = 'deep:$u${s.isEmpty ? '' : '@$s'}';
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: currentSource,
        builder: (_, src, _) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            if (src.startsWith('u/'))
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(avatar: const Icon(Icons.face_outlined, size: 16), label: Text(src), selected: true, onSelected: (_) => pickUser(context)),
              ),
            for (final (k, l) in [('home', 'Home'), ('submitted', 'My posts'), ('saved', 'Saved'), ('upvoted', 'Upvoted')])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(l), selected: src == k, onSelected: (_) => currentSource.value = k),
              ),
            ChoiceChip(
              avatar: const Icon(Icons.search, size: 16),
              label: Text(src.startsWith('r/') ? src : 'Subreddit'),
              selected: src.startsWith('r/'),
              onSelected: (_) => pickSub(context),
            ),
          ]),
        ),
      );
}

