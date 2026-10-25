import 'clean.dart';
import 'package:flutter/material.dart';
import 'glass.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'archive.dart';
import 'public_sources.dart';
import 'auth.dart';
import 'db.dart';
import 'main.dart';
import 'models.dart';

Future<String?> askClientId(BuildContext context) async {
  final c = TextEditingController(text: Auth.i.clientId ?? '');
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Reddit client ID'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Create an "installed app" at reddit.com/prefs/apps with redirect URI:\nredditgallery://auth\nthen paste its client ID here.',
            style: TextStyle(fontSize: 13)),
        const SizedBox(height: 12),
        TextField(controller: c, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Client ID')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
      ],
    ),
  );
}

Future<void> startLogin(BuildContext context) async {
  if (Auth.i.clientId == null) {
    final id = await askClientId(context);
    if (id == null || id.isEmpty) return;
    await Auth.i.setClientId(id);
  }
  await Auth.i.login();
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    Auth.i.addListener(_r);
  }

  void _r() => mounted ? setState(() {}) : null;
  @override
  void dispose() {
    Auth.i.removeListener(_r);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = Auth.i;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(flexibleSpace: const GlassBar(), title: const Text('Settings')),
      body: ListView(padding: bodyPadding(context, h: 0, v: 0), children: [
        ListTile(
          leading: const Icon(Icons.key),
          title: const Text('Reddit client ID'),
          subtitle: Text(a.clientId ?? 'Not set. Tap to paste'),
          onTap: () async {
            final id = await askClientId(context);
            if (id != null) await a.setClientId(id);
          },
        ),
        ListTile(
          leading: const Icon(Icons.person),
          title: Text(a.loggedIn ? 'Logged in as u/${a.username ?? '…'}' : 'Not logged in'),
          trailing: a.loggedIn
              ? TextButton(onPressed: () => a.logout(), child: const Text('Log out'))
              : FilledButton(onPressed: () => startLogin(context), child: const Text('Log in')),
        ),
        if (a.lastError != null) ListTile(title: Text(a.lastError!, style: const TextStyle(color: accent))),
        const Divider(),
        ValueListenableBuilder(
          valueListenable: themeMode,
          builder: (_, m, _) => ListTile(
            leading: const Icon(Icons.dark_mode),
            title: const Text('Theme'),
            trailing: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {m},
              onSelectionChanged: (s) async {
                themeMode.value = s.first;
                (await SharedPreferences.getInstance()).setInt('theme', s.first.index);
              },
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.network_check),
          title: const Text('Test archives'),
          subtitle: const Text('Ping PullPush and Arctic Shift and show the HTTP result'),
          onTap: () async {
            showDialog(context: context, builder: (ctx) => AlertDialog(
              title: const Text('Archive test'),
              content: FutureBuilder<List<String>>(
                future: Archive.test(),
                builder: (_, f) => f.hasData
                    ? SingleChildScrollView(child: SelectableText(f.data!.join('\n\n'), style: const TextStyle(fontSize: 12, fontFamily: 'monospace')))
                    : const SizedBox(height: 64, child: Center(child: CircularProgressIndicator())),
              ),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
            ));
          },
        ),
        const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 0), child: Text('Deep profile archives (drag to reorder)', style: TextStyle(fontWeight: FontWeight.w600))),
        ValueListenableBuilder(
          valueListenable: ArchiveConfig.order,
          builder: (_, order, _) => ValueListenableBuilder(
            valueListenable: ArchiveConfig.enabled,
            builder: (_, en, _) => ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (a, b) {
                final l = [...order];
                l.insert(b, l.removeAt(a));
                ArchiveConfig.order.value = l;
                ArchiveConfig.save();
              },
              children: [
                for (var i = 0; i < order.length; i++)
                  SwitchListTile(
                    key: ValueKey(order[i]),
                    secondary: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                    title: Text(archiveLabels[order[i]]!),
                    subtitle: Text(order[i] == ArchiveProvider.pullpush ? 'api.pullpush.io (needs a paid key now)' : 'arctic-shift.photon-reddit.com'),
                    value: en.contains(order[i]),
                    onChanged: (v) {
                      final s = {...en};
                      v ? s.add(order[i]) : s.remove(order[i]);
                      ArchiveConfig.enabled.value = s;
                      ArchiveConfig.save();
                    },
                  ),
              ],
            ),
          ),
        ),
        ValueListenableBuilder(
          valueListenable: ArchiveConfig.pullpushKey,
          builder: (_, k, _) => ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('PullPush API key (optional)'),
            subtitle: Text(k.isEmpty ? 'Not set. PullPush blocks free API traffic; add a paid key here.' : 'Set (sent only to api.pullpush.io)'),
            onTap: () async {
              final c = TextEditingController(text: k);
              final v = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
                title: const Text('PullPush API key'),
                content: TextField(controller: c, obscureText: true, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Key (leave empty to remove)')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
                ],
              ));
              if (v != null) await ArchiveConfig.setPullpushKey(v);
            },
          ),
        ),
        const Divider(),
        ValueListenableBuilder(
          valueListenable: originalQuality,
          builder: (_, on, _) => SwitchListTile(
            title: const Text('Original quality'),
            subtitle: const Text('Viewer and downloads use the original upload (i.redd.it / imgur original) instead of Reddit\'s resized preview. Grid thumbnails stay small.'),
            value: on,
            onChanged: (v) => originalQuality.value = v,
          ),
        ),
        ValueListenableBuilder(
          valueListenable: cleanDownloads,
          builder: (_, on, _) => SwitchListTile(
            title: const Text('Clean downloads (remove metadata)'),
            subtitle: const Text('Strips EXIF, GPS, XMP, IPTC and comments from saved pictures. Files get a plain timestamp name. Nothing is added.'),
            value: on,
            onChanged: (v) => cleanDownloads.value = v,
          ),
        ),
        const Divider(),
        const ListTile(dense: true, title: Text('No-login public sources (Deep Search)'),
            subtitle: Text('Used when logged out, in order: Reddit JSON → Reddit RSS → Redlib → archives. Merged by post id.')),
        ValueListenableBuilder(
          valueListenable: RedlibConfig.rssEnabled,
          builder: (_, on, _) => SwitchListTile(
            title: const Text('Reddit RSS feed'),
            subtitle: const Text('reddit.com/user/NAME/submitted/.rss: latest posts with images'),
            value: on,
            onChanged: (v) { RedlibConfig.rssEnabled.value = v; RedlibConfig.save(); },
          ),
        ),
        ValueListenableBuilder(
          valueListenable: RedlibConfig.enabled,
          builder: (_, on, _) => SwitchListTile(
            title: const Text('Redlib instances'),
            subtitle: const Text('Public Reddit front-ends; tries the next instance if one fails'),
            value: on,
            onChanged: (v) { RedlibConfig.enabled.value = v; RedlibConfig.save(); },
          ),
        ),
        ValueListenableBuilder(
          valueListenable: RedlibConfig.preferred,
          builder: (_, cur, _) => ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Preferred Redlib instance'),
            subtitle: Text(cur),
            onTap: () async {
              final c = TextEditingController(text: cur);
              final v = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
                title: const Text('Redlib instance'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final d in RedlibConfig.defaults)
                    ListTile(dense: true, title: Text(d), onTap: () => Navigator.pop(ctx, d)),
                  TextField(controller: c, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Custom https://… URL')),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
                ],
              ));
              if (v != null && v.trim().startsWith('https://')) {
                RedlibConfig.preferred.value = v.trim().replaceAll(RegExp(r'/+$'), '');
                await RedlibConfig.save();
              }
            },
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('Clear cached posts'),
          onTap: () async {
            await Db.clearAll();
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cache cleared')));
          },
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Hobee v$appVersion'),
          subtitle: Text('No ads, no analytics, no tracking. Downloads go to Pictures and Movies.'),
        ),
      ]),
    );
  }
}
