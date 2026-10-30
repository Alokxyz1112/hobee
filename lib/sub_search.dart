import 'relevance.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'archive.dart';
import 'db.dart';
import 'filters.dart';
import 'models.dart';
import 'nav.dart';
import 'sub_users.dart';

/// Subreddit Search: browse or search everything posted in a subreddit, no account needed.
/// Source key: "sr:NAME" or "sr:NAME?q=words&a=author".
bool isSubSearch(String s) => s.startsWith('sr:');

({String sub, String q, String author}) subParts(String s) {
  final body = s.substring(3);
  final i = body.indexOf('?');
  if (i < 0) return (sub: body, q: '', author: '');
  final m = Uri.splitQueryString(body.substring(i + 1));
  return (sub: body.substring(0, i), q: m['q'] ?? '', author: m['a'] ?? '');
}

String subKey(String sub, {String q = '', String author = ''}) {
  final m = {if (q.trim().isNotEmpty) 'q': q.trim(), if (author.trim().isNotEmpty) 'a': author.trim()};
  return 'sr:$sub${m.isEmpty ? '' : '?${Uri(queryParameters: m).query}'}';
}

final cleanSubName = RegExp(r'^/?r/', caseSensitive: false);
final validSub = RegExp(r'^[A-Za-z0-9_]{2,30}$');

/// Results options that only re-filter what is loaded (no refetch).
enum SrSort { newest, top, comments }
const srSortLabels = {SrSort.newest: 'New', SrSort.top: 'Top score', SrSort.comments: 'Most comments'};
final srSort = ValueNotifier<SrSort>(SrSort.newest);
/// Adult posts never show (they are also dropped when parsed).
bool subOk(Post p) => p.raw['over_18'] != true;

void srSortList(List<Post> l) {
  num k(Post p) => srSort.value == SrSort.top ? ((p.raw['score'] as num?) ?? 0) : ((p.raw['num_comments'] as num?) ?? 0);
  if (srSort.value != SrSort.newest) l.sort((a, b) => k(b).compareTo(k(a)));
}

void resetSubOptions() {
  srSort.value = SrSort.newest;
}

class SubSearch {
  /// Next page (older) for [source]; returns new post count, -1 when there is nothing more.
  static Future<int> fetchMore(String source, {bool fromStart = false}) async {
    final p = subParts(source);
    final (cur, done) = await Db.cursor(source);
    if (done && !fromStart) return -1;
    final r = dateRange.value;
    final end = r == null ? null : r.end.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
    final start = r == null ? null : r.start.millisecondsSinceEpoch ~/ 1000;
    int? before = fromStart ? null : int.tryParse(cur ?? '');
    if (end != null && (before == null || before > end)) before = end;
    if (start != null && before != null && before <= start) return -1;
    final rows = await Archive.subPage(p.sub, title: parseQuery(p.q).serverTitle, author: p.author, after: start, before: before);
    final posts = <Post>[];
    int? oldest;
    for (final d in rows) {
      final c = d['_hobee_cursor'];
      final t = c is num ? c.toInt() : ((d['created_utc'] as num?)?.toInt());
      if (t != null && (oldest == null || t < oldest)) oldest = t;
      if (c != null) continue;
      final x = Post.fromJson(d);
      if (x != null) posts.add(x);
    }
    await Db.savePosts(source, posts);
    final full = rows.length >= 100;
    if (fromStart && cur != null) return posts.length;
    if (!full && r != null) return posts.isEmpty ? -1 : posts.length; // range ran out, not the sub
    await Db.setCursor(source, full ? '$oldest' : null);
    return posts.isEmpty && !full ? -1 : posts.length;
  }
}

/// Subreddits searched, newest first.
class SubHistory {
  static const _k = 'subHistory';
  static final items = ValueNotifier<List<String>>(const []);
  static SharedPreferences? _sp;
  static Future<void> load() async {
    _sp = await SharedPreferences.getInstance();
    items.value = _sp!.getStringList(_k) ?? const [];
  }

  static void _save(List<String> l) {
    items.value = l.take(30).toList();
    _sp?.setStringList(_k, items.value);
  }

  static void touch(String sub) => _save([sub, ...items.value.where((s) => s.toLowerCase() != sub.toLowerCase())]);
  static void remove(String sub) => _save(items.value.where((s) => s != sub).toList());
  static void clear() => _save(const []);
}

/// Open Subreddit Search results in the Deep Search tab.
void openSubSearch(String sub, {String q = '', String author = ''}) {
  final s = sub.trim().replaceFirst(cleanSubName, '');
  if (!validSub.hasMatch(s)) return;
  SubHistory.touch(s);
  deepReturn.value = null;
  deepSource.value = subKey(s, q: q, author: author);
  mainTab.value = 1;
}

/// Subs seen in history and in recent searches, for autocomplete without the network.
List<String> localSubs() {
  final out = <String>[...SubHistory.items.value];
  for (final r in [...Recents.get(Recents.search), ...Recents.get(Recents.deep)]) {
    final m = RegExp(r'r/([A-Za-z0-9_]{2,30})').firstMatch(r) ?? RegExp(r'@([A-Za-z0-9_]{2,30})$').firstMatch(r);
    if (m != null && !out.any((x) => x.toLowerCase() == m.group(1)!.toLowerCase())) out.add(m.group(1)!);
  }
  return out;
}

/// Subreddit form: name with autocomplete, keywords, optional author, and history.
class SubSearchForm extends StatefulWidget {
  final String initial;
  const SubSearchForm({super.key, this.initial = ''});
  @override
  State<SubSearchForm> createState() => _SubSearchFormState();
}

class _SubSearchFormState extends State<SubSearchForm> {
  late final sub = TextEditingController(text: widget.initial);
  final q = TextEditingController(), author = TextEditingController();
  String? err;
  List<String> remote = const [];
  Timer? _t;
  int _req = 0;

  @override
  void dispose() {
    _t?.cancel();
    sub.dispose();
    q.dispose();
    author.dispose();
    super.dispose();
  }

  void _typed(String v) {
    _t?.cancel();
    final x = v.trim().replaceFirst(cleanSubName, '');
    setState(() {});
    if (x.length < 2) return;
    final id = ++_req;
    _t = Timer(const Duration(milliseconds: 350), () async {
      try {
        final l = await Archive.subNames(x);
        if (mounted && id == _req) setState(() => remote = l);
      } catch (_) {}
    });
  }

  void _go([String? name]) {
    final s = (name ?? sub.text).trim().replaceFirst(cleanSubName, '');
    if (!validSub.hasMatch(s)) {
      setState(() => err = 'Enter a subreddit name');
      return;
    }
    FocusScope.of(context).unfocus();
    clearFilters();
    resetSubOptions();
    openSubSearch(s, q: q.text, author: author.text.trim().replaceFirst(cleanUser, ''));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typed = sub.text.trim().replaceFirst(cleanSubName, '').toLowerCase();
    final local = localSubs();
    final picks = <String>[
      ...local.where((s) => typed.isEmpty || s.toLowerCase().startsWith(typed)),
      ...remote.where((r) => !local.any((l) => l.toLowerCase() == r.toLowerCase()) && r.toLowerCase().startsWith(typed)),
    ].take(10).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Browse or search everything posted in any subreddit, from public archives. No login needed.',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
      const SizedBox(height: 16),
      TextField(
        controller: sub,
        textInputAction: TextInputAction.next,
        onChanged: _typed,
        decoration: InputDecoration(prefixText: 'r/', labelText: 'Subreddit', errorText: err, border: const OutlineInputBorder()),
      ),
      if (typed.isNotEmpty && picks.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final s in picks) ActionChip(label: Text('r/$s'), onPressed: () => setState(() { sub.text = s; remote = const []; })),
          ]),
        ),
      const SizedBox(height: 12),
      TextField(
        controller: q,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(labelText: 'Keywords (optional)', hintText: 'words in the title or text', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: author,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _go(),
        decoration: const InputDecoration(prefixText: 'u/', labelText: 'Only from this user (optional)', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: _go, icon: const Icon(Icons.travel_explore), label: const Text('Search subreddit')),
      const SizedBox(height: 20),
      ValueListenableBuilder(
        valueListenable: SubHistory.items,
        builder: (_, items, _) => items.isEmpty
            ? const SizedBox()
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Expanded(child: Text('Recent subreddits', style: TextStyle(fontWeight: FontWeight.bold))),
                  TextButton(onPressed: SubHistory.clear, child: const Text('Clear')),
                ]),
                for (final s in items.take(15))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const CircleAvatar(radius: 16, child: Text('r/', style: TextStyle(fontSize: 12))),
                    title: Text('r/$s'),
                    onTap: () => _go(s),
                    trailing: IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Remove', onPressed: () => SubHistory.remove(s)),
                  ),
              ]),
      ),
    ]);
  }
}

/// Results header: sort, and a strip of recent subreddits to switch quickly.
class SubResultsHeader extends StatelessWidget {
  final String current;
  const SubResultsHeader({super.key, required this.current});

  @override
  Widget build(BuildContext context) {
    final p = subParts(current);
    return ListenableBuilder(
      listenable: Listenable.merge([srSort, SubHistory.items]),
      builder: (context, _) {
        final others = SubHistory.items.value.where((s) => s.toLowerCase() != p.sub.toLowerCase()).take(8).toList();
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            for (final s in SrSort.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text(srSortLabels[s]!), selected: srSort.value == s, onSelected: (_) => srSort.value = s),
              ),
            if (p.q.isNotEmpty) Padding(padding: const EdgeInsets.only(right: 6), child: InputChip(label: Text('"${p.q}"'), onDeleted: () => openSubSearch(p.sub, author: p.author))),
            if (p.author.isNotEmpty)
              Padding(padding: const EdgeInsets.only(right: 6), child: InputChip(label: Text('u/${p.author}'), onDeleted: () => openSubSearch(p.sub, q: p.q))),
            for (final s in others)
              Padding(padding: const EdgeInsets.only(right: 6), child: ActionChip(label: Text('r/$s'), onPressed: () { clearFilters(); openSubSearch(s); })),
          ]),
        );
      },
    );
  }
}

/// u/name that opens that user's Deep Search.
class AuthorLink extends StatelessWidget {
  final String author;
  final TextStyle? style;
  const AuthorLink(this.author, {super.key, this.style});
  @override
  Widget build(BuildContext context) {
    final ok = validName.hasMatch(author) && author != '[deleted]';
    return GestureDetector(
      onTap: ok
          ? () => openAuthor(context, author)
          : null,
      child: Text('u/$author', style: (style ?? const TextStyle()).copyWith(decoration: ok ? TextDecoration.underline : null)),
    );
  }
}
