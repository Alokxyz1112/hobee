import 'package:flutter/material.dart';
import 'app_lock.dart';
import 'following.dart';
import 'follows.dart';
import 'follows_ui.dart';
import 'nav.dart';

/// Open the Following feed of [profile] (default: the active one) in the Deep Search tab. No login needed.
Future<void> openFollowing([int? profile]) async {
  final all = await FollowStore.profiles();
  final id = profile ?? FollowStore.active.value ?? all.first.id;
  // Locked list: ask for an unlock first (once until the app locks again).
  final name = all.where((p) => p.id == id).map((p) => p.name).firstOrNull ?? 'this list';
  if (!await AppLock.allowProfile(id, name)) return;
  await FollowStore.setActive(id);
  deepReturn.value = null;
  deepPrev.value = null;
  deepSource.value = followingKey(id);
  mainTab.value = 1;
}

/// Deep Search → Following: pick a profile, open its feed, or manage the lists.
class FollowingPanel extends StatefulWidget {
  const FollowingPanel({super.key});
  @override
  State<FollowingPanel> createState() => _FollowingPanelState();
}

class _FollowingPanelState extends State<FollowingPanel> {
  List<(Profile, int, int)> rows = const []; // profile, subs, users

  @override
  void initState() {
    super.initState();
    FollowStore.version.addListener(_load);
    FollowStore.active.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    FollowStore.version.removeListener(_load);
    FollowStore.active.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final out = <(Profile, int, int)>[];
    for (final p in await FollowStore.profiles()) {
      final fs = await FollowStore.follows(p.id);
      final s = fs.where((f) => f.kind == FollowKind.sub).length;
      out.add((p, s, fs.length - s));
    }
    if (mounted) setState(() => rows = out);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('New posts from the subreddits and users in a profile, merged by date. Comes from public archives, so no login '
          'is needed; the first load checks each entry once and can take a few minutes for big lists.',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
      const SizedBox(height: 12),
      for (final (p, s, u) in rows)
        Card(
          child: ListTile(
            key: ValueKey('fol-${p.id}'),
            leading: Icon(p.id == FollowStore.active.value ? Icons.radio_button_checked : Icons.radio_button_off, color: cs.primary),
            title: Text(p.name),
            subtitle: Text('$s subreddits · $u users'),
            trailing: const Icon(Icons.chevron_right),
            enabled: s + u > 0,
            onTap: () => openFollowing(p.id),
          ),
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FollowsScreen())),
        icon: const Icon(Icons.playlist_add_check),
        label: Text(rows.every((r) => r.$2 + r.$3 == 0) ? 'Import a list' : 'Manage lists'),
      ),
    ]);
  }
}

/// Progress line shown above the Following feed.
class FollowingStatusBar extends StatelessWidget {
  const FollowingStatusBar({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: followingStatus,
        builder: (_, s, _) => s == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(s, key: const Key('following-status'), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
              ),
      );
}

/// All · From subreddits · From users, under the Following status line.
class FollowingKindChips extends StatelessWidget {
  const FollowingKindChips({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: followingKind,
        builder: (_, k, _) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(children: [
            for (final (i, label, icon) in const [(0, 'All', Icons.all_inclusive), (1, 'From subreddits', Icons.forum_outlined), (2, 'From users', Icons.person_outline)])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: ValueKey('fol-kind-$i'),
                  avatar: Icon(icon, size: 18),
                  label: Text(label),
                  selected: k == i,
                  showCheckmark: false,
                  onSelected: (_) => followingKind.value = i,
                ),
              ),
          ]),
        ),
      );
}
