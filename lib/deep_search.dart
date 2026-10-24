import 'package:flutter/material.dart';
import 'glass.dart';
import 'filters.dart';
import 'nav.dart';
import 'posts_view.dart';

/// Deep Search tab: archive lookup of a user's older and deleted posts. Works without login.
class DeepSearchScreen extends StatefulWidget {
  const DeepSearchScreen({super.key});
  @override
  State<DeepSearchScreen> createState() => _DeepSearchScreenState();
}

class _DeepSearchScreenState extends State<DeepSearchScreen> {
  final user = TextEditingController(), sub = TextEditingController();
  String? err;

  @override
  void initState() {
    super.initState();
    deepSource.addListener(_r);
    deepPrefill.addListener(_prefill);
    _prefill();
  }

  void _r() => mounted ? setState(() {}) : null;

  void _prefill() {
    final p = deepPrefill.value;
    if (p == null) return;
    user.text = p.$1;
    sub.text = p.$2;
    deepPrefill.value = null;
  }

  @override
  void dispose() {
    deepSource.removeListener(_r);
    deepPrefill.removeListener(_prefill);
    super.dispose();
  }

  void _go() {
    final u = user.text.trim().replaceFirst(cleanUser, '');
    final s = sub.text.trim().replaceFirst(cleanSub, '');
    if (!validName.hasMatch(u)) {
      setState(() => err = 'Enter a valid username');
      return;
    }
    setState(() => err = null);
    FocusScope.of(context).unfocus();
    openDeepSearch(user: u, sub: s);
  }

  void _edit() {
    final cur = deepSource.value;
    if (cur != null) {
      final p = cur.substring(5).split('@');
      user.text = p[0];
      sub.text = p.length > 1 ? p[1] : '';
    }
    deepSource.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final src = deepSource.value;
    if (src != null) {
      return PostsView(
        key: ValueKey(src),
        title: 'u/${src.substring(5).replaceFirst('@', ' · r/')}',
        sources: false,
        leading: IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'New deep search', onPressed: _edit),
      );
    }
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(flexibleSpace: const GlassBar(), title: const Text('Deep Search', style: TextStyle(fontWeight: FontWeight.bold))),
      body: ValueListenableBuilder(
        valueListenable: Recents.changed,
        builder: (_, _, _) {
          final recent = Recents.get(Recents.deep);
          return ListView(padding: bodyPadding(context), children: [
            Text('Find a user\'s older and deleted posts from public archives (PullPush, Arctic Shift). No login needed.',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: 16),
            TextField(
              controller: user,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(prefixText: 'u/', labelText: 'Username', errorText: err, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: sub,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _go(),
              decoration: const InputDecoration(prefixText: 'r/', labelText: 'Subreddit (optional)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 4),
            ValueListenableBuilder(
              valueListenable: hideDupesDeep,
              builder: (_, v, _) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Hide duplicates'),
                subtitle: const Text('Collapse reposts of the same image/gallery'),
                value: v,
                onChanged: (x) => hideDupesDeep.value = x,
              ),
            ),
            const SizedBox(height: 4),
            FilledButton.icon(onPressed: _go, icon: const Icon(Icons.manage_search), label: const Text('Deep search')),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 24),
              Row(children: [
                Expanded(child: Text('Recent deep searches', style: Theme.of(context).textTheme.titleSmall)),
                TextButton(onPressed: () => Recents.clear(Recents.deep), child: const Text('Clear')),
              ]),
              for (final r in recent)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text('u/${r.replaceFirst('@', ' · r/')}'),
                  trailing: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Recents.remove(Recents.deep, r)),
                  onTap: () {
                    final p = r.split('@');
                    openDeepSearch(user: p[0], sub: p.length > 1 ? p[1] : null);
                  },
                ),
            ],
          ]);
        },
      ),
    );
  }
}
