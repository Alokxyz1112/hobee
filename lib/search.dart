import 'dart:async';
import 'package:flutter/material.dart';
import 'sub_search.dart';
import 'glass.dart';
import 'api.dart';
import 'auth.dart';
import 'main.dart';
import 'nav.dart';
import 'posts_view.dart';
import 'source_bar.dart';

/// Search tab: find any Reddit user or subreddit.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final q = TextEditingController();
  bool users = true, loading = false;
  String? error;
  List<Map<String, dynamic>> results = [];
  Timer? _deb;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    Auth.i.addListener(_r);
  }

  void _r() => mounted ? setState(() {}) : null;

  @override
  void dispose() {
    Auth.i.removeListener(_r);
    _deb?.cancel();
    super.dispose();
  }

  String get _name => q.text.trim().replaceFirst(users ? cleanUser : cleanSub, '');

  void _changed(String _) {
    setState(() {});
    _deb?.cancel();
    _deb = Timer(const Duration(milliseconds: 400), _search);
  }

  Future<void> _search() async {
    final n = _name;
    final g = ++_gen;
    if (n.length < 2 || !Auth.i.loggedIn) {
      setState(() { results = []; error = null; loading = false; });
      return;
    }
    setState(() { loading = true; error = null; });
    try {
      final j = await Api.get(users ? '/users/search' : '/subreddits/search', {'q': n, 'limit': '25'});
      if (g != _gen) return;
      results = [
        for (final c in j['data']['children'] as List)
          if (!_adult(Map<String, dynamic>.from(c['data']))) Map<String, dynamic>.from(c['data'])
      ];
    } catch (e) {
      if (g == _gen) error = '$e';
    }
    if (mounted && g == _gen) setState(() => loading = false);
  }

  /// Adult subreddits and profiles are never listed.
  static bool _adult(Map<String, dynamic> d) {
    final sub = d['subreddit'];
    return d['over18'] == true || d['over_18'] == true || (sub is Map && sub['over_18'] == true);
  }

  void _open(String name, bool user) {
    if (!validName.hasMatch(name) && !(name.length <= 21 && RegExp(r'^[A-Za-z0-9_]+$').hasMatch(name))) return;
    Recents.add(Recents.search, '${user ? 'u' : 'r'}/$name');
    FocusScope.of(context).unfocus();
    currentSource.value = '${user ? 'u' : 'r'}/$name';
    Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileScreen(name: name, user: user)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = _name;
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(flexibleSpace: const GlassBar(), 
        title: const Text('Search', style: TextStyle(fontWeight: FontWeight.bold)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(112),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(children: [
              TextField(
                controller: q,
                onChanged: _changed,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => n.isEmpty ? null : _open(n, users),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  prefixText: users ? 'u/' : 'r/',
                  hintText: users ? 'username' : 'subreddit',
                  isDense: true,
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                  suffixIcon: q.text.isEmpty ? null : IconButton(icon: const Icon(Icons.close), onPressed: () { q.clear(); _changed(''); }),
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, icon: Icon(Icons.person_outline), label: Text('Users')),
                  ButtonSegment(value: false, icon: Icon(Icons.forum_outlined), label: Text('Subreddits')),
                ],
                selected: {users},
                onSelectionChanged: (s) { setState(() { users = s.first; results = []; }); _search(); },
              ),
            ]),
          ),
        ),
      ),
      body: ValueListenableBuilder(
        valueListenable: Recents.changed,
        builder: (_, _, _) {
          final recent = Recents.get(Recents.search);
          return ListView(padding: bodyPadding(context, h: 0, v: 0), children: [
            if (loading) const LinearProgressIndicator(),
            if (n.length >= 2)
              ListTile(
                leading: CircleAvatar(backgroundColor: cs.primary, foregroundColor: cs.onPrimary, child: Icon(users ? Icons.person : Icons.forum)),
                title: Text('Open ${users ? 'u' : 'r'}/$n'),
                subtitle: Text(Auth.i.loggedIn ? 'Go directly' : 'Exact name · log in to see suggestions'),
                onTap: () => _open(n, users),
              ),
            if (error != null) Padding(padding: const EdgeInsets.all(16), child: Text(error!, style: TextStyle(color: cs.error))),
            for (final r in results) users ? _userTile(r) : _subTile(r),
            if (n.length < 2 && recent.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
                child: Row(children: [
                  Expanded(child: Text('Recent searches', style: Theme.of(context).textTheme.titleSmall)),
                  TextButton(onPressed: () => Recents.clear(Recents.search), child: const Text('Clear')),
                ]),
              ),
              for (final r in recent)
                ListTile(
                  leading: Icon(r.startsWith('u/') ? Icons.person_outline : Icons.forum_outlined),
                  title: Text(r),
                  trailing: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Recents.remove(Recents.search, r)),
                  onTap: () => _open(r.substring(2), r.startsWith('u/')),
                ),
            ],
            if (n.length < 2 && recent.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text('Search any Reddit user or subreddit.', textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
              ),
          ]);
        },
      ),
    );
  }

  Widget _avatar(String? url, IconData fb) {
    final u = (url ?? '').split('?').first;
    return CircleAvatar(
      backgroundImage: u.startsWith('http') ? NetworkImage(url!) : null,
      child: u.startsWith('http') ? null : Icon(fb),
    );
  }

  Widget _userTile(Map<String, dynamic> d) {
    final name = '${d['name']}';
    final karma = (d['link_karma'] ?? 0) + (d['comment_karma'] ?? 0);
    return ListTile(
      leading: _avatar(d['icon_img'] as String?, Icons.person),
      title: Text('u/$name'),
      subtitle: Text('$karma karma${d['is_suspended'] == true ? ' · suspended' : ''}'),
      onTap: () => _open(name, true),
    );
  }

  Widget _subTile(Map<String, dynamic> d) {
    final name = '${d['display_name']}';
    final icon = (d['community_icon'] as String?)?.isNotEmpty == true ? d['community_icon'] as String : d['icon_img'] as String?;
    return ListTile(
      leading: _avatar(icon, Icons.forum),
      title: Text('r/$name'),
      subtitle: Text('${d['subscribers'] ?? 0} members · ${d['public_description'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => _open(name, false),
      trailing: IconButton(icon: const Icon(Icons.travel_explore), tooltip: 'Search all its posts', onPressed: () => openSubSearch(name)),
    );
  }
}

/// A user's or subreddit's posts, opened from Search.
class ProfileScreen extends StatelessWidget {
  final String name;
  final bool user;
  const ProfileScreen({super.key, required this.name, required this.user});

  void _deep(BuildContext context) {
    Navigator.pop(context);
    deepPrefill.value = (name, '');
    openDeepSearch(user: name);
  }

  @override
  Widget build(BuildContext context) {
    if (!Auth.i.loggedIn) {
      return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
        appBar: AppBar(flexibleSpace: const GlassBar(), title: Text('${user ? 'u' : 'r'}/$name')),
        body: Column(children: [
          const Expanded(child: LoginPrompt()),
          if (user)
            Padding(
              padding: const EdgeInsets.all(24),
              child: OutlinedButton.icon(onPressed: () => _deep(context), icon: const Icon(Icons.manage_search), label: const Text('Deep search this user (no login)')),
            ),
        ]),
      );
    }
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: PostsView(
        title: '${user ? 'u' : 'r'}/$name',
        sources: false,
        leading: const BackButton(),
      ),
      floatingActionButton: user
          ? FloatingActionButton.extended(onPressed: () => _deep(context), icon: const Icon(Icons.manage_search), label: const Text('Deep search this user'))
          : null,
    );
  }
}
