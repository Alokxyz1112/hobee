import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'follows.dart';

Future<String?> _askName(BuildContext context, String title, {String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'Profile name'), onSubmitted: (v) => Navigator.pop(ctx, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
}

/// Settings → Following lists: profiles, their subreddits/users, import and export.
class FollowsScreen extends StatefulWidget {
  const FollowsScreen({super.key});
  @override
  State<FollowsScreen> createState() => _FollowsScreenState();
}

class _FollowsScreenState extends State<FollowsScreen> {
  List<Profile> profiles = const [];
  int? shown;
  List<Follow> follows = const [];
  String filter = '';

  @override
  void initState() {
    super.initState();
    FollowStore.version.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    FollowStore.version.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final ps = await FollowStore.profiles();
    final id = ps.any((p) => p.id == shown) ? shown! : (ps.any((p) => p.id == FollowStore.active.value) ? FollowStore.active.value! : ps.first.id);
    final fs = await FollowStore.follows(id);
    if (!mounted) return;
    setState(() {
      profiles = ps;
      shown = id;
      follows = fs;
    });
  }

  Future<void> _newProfile() async {
    final n = (await _askName(context, 'New profile'))?.trim() ?? '';
    if (n.isEmpty) return;
    try {
      shown = await FollowStore.createProfile(n);
    } catch (_) {
      _snack('A profile named "$n" already exists');
    }
  }

  Future<void> _rename() async {
    final cur = profiles.firstWhere((p) => p.id == shown);
    final n = (await _askName(context, 'Rename profile', initial: cur.name))?.trim() ?? '';
    if (n.isEmpty || n == cur.name) return;
    try {
      await FollowStore.renameProfile(cur.id, n);
    } catch (_) {
      _snack('A profile named "$n" already exists');
    }
  }

  Future<void> _delete() async {
    final cur = profiles.firstWhere((p) => p.id == shown);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${cur.name}"?'),
        content: Text('Its ${follows.length} subreddits and users are removed from Hobees. Other profiles are not touched.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    shown = null;
    if (!await FollowStore.deleteProfile(cur.id)) _snack('The last profile can\'t be deleted');
  }

  Future<void> _export({required bool csv}) async {
    final name = profiles.firstWhere((p) => p.id == shown).name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save list',
        fileName: 'hobees_$name.${csv ? 'csv' : 'txt'}',
        bytes: utf8.encode(exportFollows(follows, csv: csv)),
      );
      if (path != null) _snack('Saved ${follows.length} entries');
    } catch (e) {
      _snack('Couldn\'t save: $e');
    }
  }

  void _snack(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final f = filter.toLowerCase();
    final list = f.isEmpty ? follows : follows.where((x) => x.name.toLowerCase().contains(f)).toList();
    final subs = follows.where((x) => x.kind == FollowKind.sub).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Following lists'),
        actions: [
          IconButton(
            tooltip: 'Import',
            icon: const Icon(Icons.playlist_add),
            onPressed: shown == null ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => ImportScreen(profile: shown!))),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'new' => _newProfile(),
              'rename' => _rename(),
              'delete' => _delete(),
              'txt' => _export(csv: false),
              'csv' => _export(csv: true),
              'copy' => Clipboard.setData(ClipboardData(text: exportFollows(follows))).then((_) => _snack('Copied ${follows.length} entries')),
              _ => null,
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'new', child: Text('New profile')),
              PopupMenuItem(value: 'rename', child: Text('Rename profile')),
              PopupMenuItem(value: 'delete', child: Text('Delete profile')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'txt', child: Text('Export as text')),
              PopupMenuItem(value: 'csv', child: Text('Export as CSV')),
              PopupMenuItem(value: 'copy', child: Text('Copy to clipboard')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        SizedBox(
          height: 56,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), children: [
            for (final p in profiles)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text(p.name), selected: p.id == shown, onSelected: (_) {
                  shown = p.id;
                  _reload();
                }),
              ),
            ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('New'), onPressed: _newProfile),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            Expanded(child: Text('$subs subreddits · ${follows.length - subs} users', style: TextStyle(color: cs.onSurfaceVariant))),
            if (shown != null && shown != FollowStore.active.value)
              TextButton(onPressed: () => FollowStore.setActive(shown!).then((_) => setState(() {})), child: const Text('Use in Following'))
            else
              Text('Shown in Following', style: TextStyle(color: cs.primary, fontSize: 12)),
          ]),
        ),
        if (follows.length > 12)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Filter', isDense: true, border: OutlineInputBorder()),
              onChanged: (v) => setState(() => filter = v),
            ),
          ),
        Expanded(
          child: follows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('No subreddits or users yet.', style: TextStyle(color: cs.onSurfaceVariant)),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: shown == null ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) => ImportScreen(profile: shown!))),
                        icon: const Icon(Icons.playlist_add),
                        label: const Text('Import a list'),
                      ),
                    ]),
                  ),
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final x = list[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(x.kind == FollowKind.sub ? Icons.forum_outlined : Icons.person_outline),
                      title: Text(x.label),
                      trailing: IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close),
                        onPressed: () => FollowStore.remove(shown!, x),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

/// Paste text or pick a .txt/.csv file, preview what was found, then save it into a profile.
class ImportScreen extends StatefulWidget {
  final int profile;
  const ImportScreen({super.key, required this.profile});
  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final text = TextEditingController();
  ImportResult result = const ImportResult([], []);
  List<Profile> profiles = const [];
  late int target = widget.profile;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    text.addListener(() => setState(() => result = parseFollowList(text.text)));
    FollowStore.profiles().then((ps) => mounted ? setState(() => profiles = ps) : null);
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) text.text = d!.text!;
  }

  Future<void> _pick() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'csv'], withData: true);
      final bytes = r?.files.single.bytes;
      if (bytes == null) return;
      text.text = utf8.decode(bytes, allowMalformed: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn\'t read the file: $e')));
    }
  }

  Future<void> _newTarget() async {
    final n = (await _askName(context, 'New profile'))?.trim() ?? '';
    if (n.isEmpty) return;
    try {
      final id = await FollowStore.createProfile(n);
      final ps = await FollowStore.profiles();
      setState(() {
        profiles = ps;
        target = id;
      });
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('A profile named "$n" already exists')));
    }
  }

  Future<void> _save() async {
    setState(() => saving = true);
    final added = await FollowStore.add(target, result.follows);
    if (!mounted) return;
    final name = profiles.where((p) => p.id == target).map((p) => p.name).firstOrNull ?? 'profile';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Added $added to $name${added < result.follows.length ? ' (${result.follows.length - added} were already there)' : ''}')));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = result;
    return Scaffold(
      appBar: AppBar(title: const Text('Import list')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Paste subreddits and users, or pick a .txt / .csv file. Accepts r/name, u/name, reddit links, '
            'multireddit links like reddit.com/r/a+b+c, u_name entries, and Reddit\'s subscribed_subreddits.csv.',
            style: TextStyle(color: cs.onSurfaceVariant)),
        const SizedBox(height: 12),
        Row(children: [
          OutlinedButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste), label: const Text('Paste')),
          const SizedBox(width: 8),
          OutlinedButton.icon(onPressed: _pick, icon: const Icon(Icons.file_open_outlined), label: const Text('Pick file')),
        ]),
        const SizedBox(height: 12),
        TextField(
          key: const Key('import-text'),
          controller: text,
          minLines: 4,
          maxLines: 8,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'r/pics u/someone https://reddit.com/r/a+b+c'),
        ),
        const SizedBox(height: 16),
        Text(
          r.follows.isEmpty && r.skipped.isEmpty ? 'Nothing found yet' : 'Found ${r.subs} subreddits and ${r.users} users${r.skipped.isEmpty ? '' : ' · ${r.skipped.length} skipped'}',
          key: const Key('import-summary'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (r.skipped.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Skipped: ${r.skipped.take(10).join(', ')}${r.skipped.length > 10 ? ' …' : ''}', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          ),
        if (r.follows.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Show list'),
            children: [
              Wrap(spacing: 6, runSpacing: 6, children: [for (final f in r.follows.take(500)) Chip(label: Text(f.label), visualDensity: VisualDensity.compact)]),
              if (r.follows.length > 500) Text('… and ${r.follows.length - 500} more'),
            ],
          ),
        const SizedBox(height: 16),
        Row(children: [
          const Text('Save to '),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<int>(
              isExpanded: true,
              value: profiles.any((p) => p.id == target) ? target : null,
              items: [for (final p in profiles) DropdownMenuItem(value: p.id, child: Text(p.name))],
              onChanged: (v) => setState(() => target = v ?? target),
            ),
          ),
          TextButton(onPressed: _newTarget, child: const Text('New profile')),
        ]),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('import-save'),
          onPressed: r.follows.isEmpty || saving ? null : _save,
          child: Text(r.follows.isEmpty ? 'Save' : 'Save ${r.follows.length}'),
        ),
      ]),
    );
  }
}
