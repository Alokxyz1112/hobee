import 'package:flutter/foundation.dart' show compute;
import 'relevance.dart';
import 'viewed.dart';
import 'dart:async';
import 'dart:convert';
import 'archive.dart';
import 'clean.dart';
import 'find.dart';
import 'find_ui.dart';
import 'clean_image.dart';
import 'package:flutter/material.dart';
import 'glass.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'db.dart';
import 'models.dart';
import 'source_bar.dart';
import 'nav.dart';
import 'sub_search.dart';

enum MediaFilter { all, images, videos, galleries, text, links, documents }

const mediaFilterLabels = {
  MediaFilter.all: 'All',
  MediaFilter.images: 'Images',
  MediaFilter.videos: 'Videos',
  MediaFilter.galleries: 'Galleries',
  MediaFilter.text: 'Text',
  MediaFilter.links: 'Links',
  MediaFilter.documents: 'Docs',
};

const mediaFilterIcons = {
  MediaFilter.all: Icons.all_inclusive,
  MediaFilter.images: Icons.image_outlined,
  MediaFilter.videos: Icons.play_circle_outline,
  MediaFilter.galleries: Icons.collections_outlined,
  MediaFilter.text: Icons.notes,
  MediaFilter.links: Icons.link,
  MediaFilter.documents: Icons.description_outlined,
};

/// Filters whose posts have no media (they show in Card / Compact, not the grid).
bool get textish => const {MediaFilter.text, MediaFilter.links, MediaFilter.documents}.contains(mediaFilter.value);

/// Live / Archive / Removed (Deep Search). Empty = any.
final statusFilter = ValueNotifier<Set<PostStatus>>({});

/// Per chip result counts for the current list (MediaFilter or PostStatus -> n).
final chipCounts = ValueNotifier<Map<Object, int>>({});

const sorts = ['best', 'hot', 'new', 'top', 'rising', 'controversial'];
const sortTimes = ['hour', 'day', 'week', 'month', 'year', 'all'];

final mediaFilter = ValueNotifier<MediaFilter>(MediaFilter.all);
final subSort = ValueNotifier<String>('new'); // e.g. "new", "top:week"
final dateRange = ValueNotifier<DateTimeRange?>(null);
final searchQuery = ValueNotifier<String>('');
final hideRead = ValueNotifier<bool>(false);
final readIds = <String>{};

/// Collapse reposts/crossposts of the same image. Separate defaults: off for feeds, on for Deep Search.
final hideDupes = ValueNotifier<bool>(false);
final hideDupesDeep = ValueNotifier<bool>(true);
/// Deep Search: hide tiles whose image is gone everywhere instead of showing 'Image gone'.
final hideGone = ValueNotifier<bool>(true);
bool get dupesOn => currentSource.value.startsWith('deep:') ? hideDupesDeep.value : hideDupes.value;
ValueNotifier<bool> get dupesNotifier => currentSource.value.startsWith('deep:') ? hideDupesDeep : hideDupes;

enum PostLayout { card, slides, compact, gallery }

final postLayout = ValueNotifier<PostLayout>(PostLayout.gallery);
SharedPreferences? _sp;

void markRead(String id) {
  if (readIds.add(id)) _sp?.setStringList('readIds', readIds.toList());
}

bool get sortable => currentSource.value == 'home' || currentSource.value.startsWith('r/') || currentSource.value.startsWith('u/');

/// Fires when anything affecting what is displayed (but not what is fetched) changes.
/// Sort by relevance while a keyword is present.
final relevanceSort = ValueNotifier<bool>(true);

/// Relevance ranking for the current source and query. Small sets rank inline; big ones in an isolate.
class Rel {
  static final ready = ValueNotifier<int>(0);
  static String _key = '';
  static Map<String, RHit>? _hits;
  static String? _pending;
  static bool active = false;

  static RQuery sourceQuery() {
    final s = currentSource.value;
    return isSubSearch(s) ? parseQuery(subParts(s).q) : RQuery.empty;
  }

  static String queryText() {
    final s = currentSource.value;
    return [if (isSubSearch(s)) subParts(s).q, searchQuery.value].where((x) => x.trim().isNotEmpty).join(' ');
  }

  static RHit? hitOf(String id) => active ? (_hits == null ? null : _hits![id]) : null;

  static RDoc docOf(Post p) {
    String s(Object? o) => o is String ? o : '';
    final url = s(p.raw['url_overridden_by_dest'] ?? p.raw['url']);
    return RDoc([
      p.title,
      '${s(p.raw['link_flair_text'])} ${s(p.raw['author_flair_text'])}',
      s(p.raw['selftext']),
      url.contains('/comments/') ? '' : '${s(p.raw['domain'])} ${Uri.tryParse(url)?.path ?? ''}',
      p.subreddit,
    ], p.author, p.created, (p.raw['score'] as num?)?.toInt() ?? 0);
  }

  static Map<String, RHit>? hitsFor(List<Post> all) {
    final qs = queryText();
    if (qs.isEmpty || parseQuery(qs).isEmpty) { active = false; return null; }
    final key = '$qs|${identityHashCode(all)}|${all.length}';
    if (key == _key) { active = true; return _hits; }
    Map<String, RHit> byId(Map<int, RHit> r) => {for (final e in r.entries) all[e.key].id: e.value};
    if (all.length <= 1500) {
      _key = key;
      _hits = byId(rankDocs([for (final p in all) docOf(p)], parseQuery(qs)));
      active = true;
      return _hits;
    }
    if (_pending != key) {
      _pending = key;
      final docs = [for (final p in all) docOf(p)];
      compute(rankJob, (docs, qs)).then((r) {
        if (_pending != key) return;
        _pending = null;
        _key = key;
        _hits = byId(r);
        ready.value++;
      });
    }
    active = false;
    return null; // plain matching until the ranked list is ready
  }
}

final viewFilters = Listenable.merge([relevanceSort, Rel.ready, mediaFilter, statusFilter, dateRange, searchQuery, hideRead, hideDupes, hideDupesDeep, hideGone, srSort]);

// ---- filters remembered per screen (home feeds vs Deep Search) ----
String _scope = 'main';
DateTimeRange? _pendingDeep;

/// Pre-set the Deep Search date filter (used by time-window suggestions).
void presetDeepRange(DateTimeRange r) {
  if (_scope == 'deep') {
    dateRange.value = r;
  } else {
    _pendingDeep = r;
  }
}
String _scopeOf(String src) => src.startsWith('deep:') ? 'deep' : 'main';

void _saveScope(SharedPreferences sp, String scope) {
  final r = dateRange.value;
  sp.setString('filters.$scope', jsonEncode({
    'm': mediaFilter.value.index,
    'q': searchQuery.value,
    'st': [for (final x in statusFilter.value) x.index],
    if (r != null) 'd': [r.start.millisecondsSinceEpoch, r.end.millisecondsSinceEpoch],
  }));
}

void _loadScope(SharedPreferences sp, String scope) {
  // Saved filters are untrusted: any bad value resets that scope instead of crashing (the app must always open).
  MediaFilter m = MediaFilter.all;
  String q = '';
  Set<PostStatus> st = {};
  DateTimeRange? r;
  try {
    final raw = jsonDecode(sp.getString('filters.$scope') ?? '{}');
    final j = raw is Map ? raw : const {};
    final mi = j['m'] is int ? j['m'] as int : (scope == 'main' ? sp.getInt('mediaFilter') ?? 0 : 0);
    m = MediaFilter.values[mi.clamp(0, MediaFilter.values.length - 1)];
    q = j['q'] is String ? j['q'] as String : '';
    st = {for (final i in (j['st'] is List ? j['st'] as List : const [])) if (i is int) PostStatus.values[i.clamp(0, PostStatus.values.length - 1)]};
    final d = j['d'];
    if (d is List && d.length == 2 && d[0] is int && d[1] is int && (d[0] as int) <= (d[1] as int)) {
      r = DateTimeRange(start: DateTime.fromMillisecondsSinceEpoch(d[0] as int), end: DateTime.fromMillisecondsSinceEpoch(d[1] as int));
    }
  } catch (_) {
    sp.remove('filters.$scope');
  }
  mediaFilter.value = m;
  searchQuery.value = q;
  statusFilter.value = st;
  dateRange.value = r;
}

/// Safe mode: wipe every saved search/filter state so nothing restored can break the app.
Future<void> resetSearchState() async {
  final sp = _sp ?? await SharedPreferences.getInstance();
  for (final k in sp.getKeys().toList()) {
    if (k.startsWith('filters.') || k == 'mediaFilter' || k == 'subSort') await sp.remove(k);
  }
  restoringFilters = false;
  relevanceSort.value = false;
  mediaFilter.value = MediaFilter.all;
  searchQuery.value = '';
  statusFilter.value = {};
  dateRange.value = null;
}

bool get anyFilter => mediaFilter.value != MediaFilter.all || searchQuery.value.isNotEmpty || statusFilter.value.isNotEmpty || dateRange.value != null;

/// True while filters are being put back after a profile; listeners must not refetch.
bool restoringFilters = false;

void clearFilters() {
  mediaFilter.value = MediaFilter.all;
  searchQuery.value = '';
  statusFilter.value = {};
  dateRange.value = null;
}

Future<void> loadFilterPrefs() async {
  final sp = await SharedPreferences.getInstance();
  _sp = sp;
  subSort.value = sp.getString('subSort') ?? 'new';
  hideRead.value = sp.getBool('hideRead') ?? false;
  originalQuality.value = sp.getBool('originalQuality') ?? true;
  cleanDownloads.value = sp.getBool('cleanDownloads') ?? true;
  cleanJpegs.value = sp.getBool('cleanJpegs') ?? true;
  cleanJpegs.addListener(() => sp.setBool('cleanJpegs', cleanJpegs.value));
  saveOriginalBytes.value = sp.getBool('saveOriginalBytes') ?? false;
  saveOriginalBytes.addListener(() => sp.setBool('saveOriginalBytes', saveOriginalBytes.value));
  cleanDownloads.addListener(() => sp.setBool('cleanDownloads', cleanDownloads.value));
  originalQuality.addListener(() => sp.setBool('originalQuality', originalQuality.value));
  hideDupes.value = sp.getBool('hideDupes') ?? false;
  hideDupesDeep.value = sp.getBool('hideDupesDeep') ?? true;
  hideGone.value = sp.getBool('hideGone') ?? true;
  hideGone.addListener(() => sp.setBool('hideGone', hideGone.value));
  hideDupes.addListener(() => sp.setBool('hideDupes', hideDupes.value));
  hideDupesDeep.addListener(() => sp.setBool('hideDupesDeep', hideDupesDeep.value));
  readIds.addAll(sp.getStringList('readIds') ?? []);
  postLayout.value = PostLayout.values[(sp.getInt('postLayout') ?? 3).clamp(0, 3)];
  hideRead.addListener(() => sp.setBool('hideRead', hideRead.value));
  postLayout.addListener(() => sp.setInt('postLayout', postLayout.value.index));
  _scope = _scopeOf(currentSource.value);
  _loadScope(sp, _scope);
  currentSource.addListener(() {
    final s = _scopeOf(currentSource.value);
    if (s == _scope) return;
    _saveScope(sp, _scope);
    _scope = s;
    _loadScope(sp, s);
    if (s == 'deep' && _pendingDeep != null) {
      dateRange.value = _pendingDeep;
      _pendingDeep = null;
    }
  });
  for (final n in [mediaFilter, statusFilter, dateRange, searchQuery]) {
    n.addListener(() => _saveScope(sp, _scope));
  }
  subSort.addListener(() => sp.setString('subSort', subSort.value));
}

/// Cache/fetch key: subreddits include sort so each sort has its own listing.
String effectiveSource() {
  final s = currentSource.value;
  if (s == 'home') return 'home|${subSort.value}';
  if (s.startsWith('r/')) return '$s|${subSort.value == 'best' ? 'hot' : subSort.value}';
  if (s.startsWith('u/')) return '$s|${const {'best': 'hot', 'rising': 'hot'}[subSort.value] ?? subSort.value}';
  return s;
}

String sortLabel(String s) {
  final p = s.split(':');
  final n = p[0][0].toUpperCase() + p[0].substring(1);
  return p.length > 1 ? '$n · ${p[1]}' : n;
}

MediaFilter kindOf(Post p) {
  if (p.media.length > 1) return MediaFilter.galleries;
  if (p.media.isNotEmpty && p.media.first.type != MediaType.image) return MediaFilter.videos;
  return MediaFilter.images;
}

bool kindMatches(Post p, MediaFilter f) => switch (f) {
      MediaFilter.all => p.media.isNotEmpty,
      MediaFilter.images || MediaFilter.videos || MediaFilter.galleries => p.media.isNotEmpty && kindOf(p) == f,
      MediaFilter.text => p.media.isEmpty && !isDocument(p) && !isLink(p),
      MediaFilter.links => isLink(p),
      MediaFilter.documents => isDocument(p),
    };

String _tq = '';
List<String> _terms = const [];
List<String> get searchTerms {
  final q = Rel.queryText();
  if (_tq != q) {
    _tq = q;
    final r = parseQuery(q);
    _terms = r.highlight.isEmpty && q.isNotEmpty && r.author == null && r.sub == null ? queryTerms(q) : r.highlight;
  }
  return _terms;
}

/// Everything except the type and status chips: read, date and the search text.
bool baseMatches(Post p, {bool text = true}) {
  if (hideRead.value && readIds.contains(p.id)) return false;
  final r = dateRange.value;
  if (r != null) {
    final d = p.date.toLocal();
    if (d.isBefore(r.start) || !d.isBefore(r.end.add(const Duration(days: 1)))) return false;
  }
  return !text || textMatches(p, searchTerms);
}

bool _statusOk(Post p, bool deep) => !deep || statusFilter.value.isEmpty || statusFilter.value.contains(statusOf(p));

bool matches(Post p) {
  if (!kindMatches(p, mediaFilter.value)) return false;
  if (!_statusOk(p, isDeep(currentSource.value))) return false;
  return baseMatches(p);
}

/// Counts for every chip given the other active filters; published to [chipCounts].
void publishCounts(List<Post> all) => filterAndCount(all);

/// One pass: publishes chip counts and returns the posts that match every filter.
/// (Was two passes per change, each running the typo matcher over every post.)
List<Post> filterAndCount(List<Post> all) {
  final deep = isDeep(currentSource.value);
  final sr = isSubSearch(currentSource.value);
  final hv = Viewed.hide.value;
  final hits = Rel.hitsFor(all);
  final mf = mediaFilter.value;
  final c = <Object, int>{};
  final out = <Post>[];
  for (final p in all) {
    if (sr && !subOk(p)) continue;
    if (sr && hv && Viewed.has(p.author)) continue;
    if (hits != null && !hits.containsKey(p.id)) continue;
    if (!baseMatches(p, text: hits == null)) continue;
    final st = _statusOk(p, deep);
    if (st && kindMatches(p, mf)) out.add(p);
    if (st) {
      for (final f in MediaFilter.values) {
        if (kindMatches(p, f)) c[f] = (c[f] ?? 0) + 1;
      }
    }
    if (deep && kindMatches(p, mediaFilter.value)) {
      final s = statusOf(p);
      c[s] = (c[s] ?? 0) + 1;
    }
  }
  if (!_sameCounts(chipCounts.value, c)) chipCounts.value = c;
  if (sr) srSortList(out);
  if (hits != null && relevanceSort.value) out.sort((a, b) => (hits[b.id]?.score ?? 0).compareTo(hits[a.id]?.score ?? 0));
  return out;
}

bool _sameCounts(Map<Object, int> a, Map<Object, int> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// Pages older listings until the oldest cached post is older than [start], or the listing ends.
/// Returns null on success or an error string.
Future<String?> pageUntil(String src, DateTime start, void Function(int pages, DateTime? oldest) prog) async {
  var pages = 0;
  try {
    while (effectiveSource() == src) {
      final posts = await Db.load(src);
      final oldest = posts.isEmpty ? null : posts.map((p) => p.created).reduce((a, b) => a < b ? a : b);
      final od = oldest == null ? null : DateTime.fromMillisecondsSinceEpoch(oldest * 1000);
      prog(pages, od);
      if (od != null && od.isBefore(start)) return null;
      final (_, done) = await Db.cursor(src);
      if (done) return null;
      final n = await Api.fetchMore(src);
      if (n < 0) return null;
      pages++;
    }
  } catch (e) {
    return '$e';
  }
  return null;
}

String _d(DateTime d) => '${d.day}/${d.month}/${d.year % 100}';

/// Compact row: media chips + date / search / sort actions.
class FilterBar extends StatelessWidget {
  const FilterBar({super.key});

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2005, 6),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: dateRange.value,
      helpText: 'Show posts between',
    );
    if (r != null) dateRange.value = r;
  }

  Future<void> _search(BuildContext context) async {
    final c = TextEditingController(text: searchQuery.value);
    final s = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Search cached posts'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Title or subreddit', prefixIcon: Icon(Icons.search)),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Clear')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Search')),
        ],
      ),
    );
    if (s != null) searchQuery.value = s.trim();
  }

  Future<void> _sort(BuildContext context) => showSortSheet(context);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([viewFilters, subSort, currentSource, chipCounts]),
      builder: (_, _) {
        final r = dateRange.value;
        final deep = isDeep(currentSource.value);
        final n = chipCounts.value;
        String lbl(String t, Object k) => n.isEmpty ? t : '$t ${n[k] ?? 0}';
        return Column(children: [
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
              child: Row(children: [
                const Expanded(child: InstantSearchField()),
                IconButton(
                  icon: Icon(Icons.date_range, color: r != null ? cs.primary : null),
                  tooltip: r == null ? 'Filter by date' : '${_d(r.start)} to ${_d(r.end)}',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _pickDate(context),
                ),
                IconButton(
                  icon: const Icon(Icons.image_search),
                  tooltip: 'Find this photo',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => findPhotoFromPicker(context),
                ),
                IconButton(
                  icon: const Icon(Icons.travel_explore),
                  tooltip: 'Search everything saved',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Navigator.push(context, fadeRoute(const CacheSearchScreen())),
                ),
                if (anyFilter)
                  IconButton(icon: const Icon(Icons.filter_alt_off_outlined), tooltip: 'Clear all', visualDensity: VisualDensity.compact, onPressed: clearFilters),
              ]),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: [
                if (sortable)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      avatar: Icon(Icons.sort, size: 16, color: cs.primary),
                      label: Text(sortLabel(subSort.value)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _sort(context),
                    ),
                  ),
                if (r != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InputChip(
                      avatar: Icon(Icons.date_range, size: 16, color: cs.primary),
                      label: Text('${_d(r.start)} to ${_d(r.end)}'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _pickDate(context),
                      onDeleted: () => dateRange.value = null,
                    ),
                  ),
                for (final f in MediaFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(lbl(mediaFilterLabels[f]!, f)),
                      avatar: Icon(mediaFilterIcons[f], size: 16),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      selected: mediaFilter.value == f,
                      onSelected: (_) => mediaFilter.value = f,
                    ),
                  ),
                if (deep) ...[
                  const SizedBox(width: 6),
                  for (final st in PostStatus.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(lbl(statusLabels[st]!, st)),
                        visualDensity: VisualDensity.compact,
                        selected: statusFilter.value.contains(st),
                        onSelected: (v) => statusFilter.value = v ? {...statusFilter.value, st} : ({...statusFilter.value}..remove(st)),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ]);
      },
    );
  }
}

/// AppBar bottom combining source tabs and filter row.
class SourceAndFilterBar extends StatelessWidget implements PreferredSizeWidget {
  final bool sources;
  const SourceAndFilterBar({super.key, this.sources = true});
  @override
  Size get preferredSize => Size.fromHeight(sources ? 140 : 92);
  @override
  Widget build(BuildContext context) => Column(children: [
        if (sources) const SizedBox(height: 48, child: SourceBar()),
        const SizedBox(height: 92, child: FilterBar()),
      ]);
}

Widget _row(BuildContext ctx, IconData icon, String label, VoidCallback onTap, {Widget? trailing}) => ListTile(
      leading: Icon(icon, color: Theme.of(ctx).colorScheme.onSurface),
      title: Text(label, style: const TextStyle(fontSize: 16)),
      trailing: trailing,
      minLeadingWidth: 40,
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      onTap: onTap,
    );

Future<T?> _sheet<T>(BuildContext context, Widget Function(BuildContext) b) => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (ctx) => Glass(
        radius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: SafeArea(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.symmetric(vertical: 10), decoration: BoxDecoration(color: Theme.of(ctx).colorScheme.onSurfaceVariant.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(2)))),
          b(ctx), const SizedBox(height: 8)]))),
      ),
    );

Future<void> showSortSheet(BuildContext context) async {
  final cur = subSort.value.split(':')[0];
  const icons = {
    'best': Icons.rocket_launch_outlined,
    'hot': Icons.local_fire_department_outlined,
    'new': Icons.new_releases_outlined,
    'rising': Icons.trending_up,
    'top': Icons.bar_chart,
    'controversial': Icons.bolt_outlined,
  };
  final home = currentSource.value == 'home';
  final k = await _sheet<String>(context, (ctx) => Column(children: [
        for (final s in ['best', 'hot', 'new', 'rising', 'top', 'controversial'])
          if (s != 'best' || home)
            _row(ctx, icons[s]!, sortLabel(s), () => Navigator.pop(ctx, s),
                trailing: cur == s ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary) : null),
      ]));
  if (k == null || !context.mounted) return;
  if (k == 'top' || k == 'controversial') {
    final curT = subSort.value.startsWith('$k:') ? subSort.value.split(':')[1] : null;
    final t = await _sheet<String>(context, (ctx) => Column(children: [
          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${sortLabel(k)} of…', style: Theme.of(ctx).textTheme.titleMedium)),
          for (final t in sortTimes)
            _row(ctx, Icons.schedule, t == 'all' ? 'All Time' : 'Past ${t[0].toUpperCase()}${t.substring(1)}', () => Navigator.pop(ctx, t),
                trailing: curT == t ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary) : null),
        ]));
    if (t != null) subSort.value = '$k:$t';
  } else {
    subSort.value = k;
  }
}

/// Requests the Home screen to switch tabs (0 = gallery grid, 1 = feed).
final homeTab = ValueNotifier<int>(0);

void applyLayout(PostLayout l) {
  postLayout.value = l;
  homeTab.value = l == PostLayout.gallery ? 0 : 1;
}

Future<void> showLayoutSheet(BuildContext context) async {
  const items = [
    (PostLayout.card, Icons.view_agenda_outlined, 'Card'),
    (PostLayout.slides, Icons.view_carousel_outlined, 'Slides'),
    (PostLayout.compact, Icons.view_list_outlined, 'Compact'),
    (PostLayout.gallery, Icons.grid_view, 'Gallery'),
  ];
  final l = await _sheet<PostLayout>(context, (ctx) => Column(children: [
        for (final (v, i, t) in items)
          _row(ctx, i, t, () => Navigator.pop(ctx, v),
              trailing: postLayout.value == v ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary) : null),
      ]));
  if (l != null) applyLayout(l);
}

Future<void> showFilterSheet(BuildContext context) => _sheet(context, (ctx) => ListenableBuilder(
      listenable: viewFilters,
      builder: (ctx, _) {
        final r = dateRange.value;
        return Column(children: [
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('Filter Posts', style: Theme.of(ctx).textTheme.titleMedium)),
          for (final f in MediaFilter.values)
            _row(ctx, mediaFilterIcons[f]!, mediaFilterLabels[f]!, () => mediaFilter.value = f,
                trailing: mediaFilter.value == f ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary) : null),
          const Divider(),
          _row(ctx, Icons.filter_none, 'Hide duplicates', () => dupesNotifier.value = !dupesNotifier.value,
              trailing: Switch(value: dupesOn, onChanged: (v) => dupesNotifier.value = v)),
          if (currentSource.value.startsWith('deep:'))
            _row(ctx, Icons.hide_image_outlined, 'Hide gone images', () => hideGone.value = !hideGone.value,
                trailing: Switch(value: hideGone.value, onChanged: (v) => hideGone.value = v)),
          _row(ctx, Icons.date_range, r == null ? 'Date range…' : '${_d(r.start)} to ${_d(r.end)}', () async {
            Navigator.pop(ctx);
            await const FilterBar()._pickDate(context);
          }, trailing: r == null ? null : IconButton(icon: const Icon(Icons.close), onPressed: () => dateRange.value = null)),
        ]);
      },
    ));

/// Main overflow sheet (Focus-style).
Future<void> showActionsSheet(BuildContext context, {required Future<void> Function() onRefresh, required VoidCallback onTop, required VoidCallback onRandom}) {
  return _sheet(context, (ctx) {
    void go(VoidCallback f) { Navigator.pop(ctx); f(); }
    return ValueListenableBuilder(
      valueListenable: hideRead,
      builder: (ctx, h, _) => Column(children: [
        _row(ctx, Icons.refresh, 'Refresh', () => go(onRefresh)),
        if (sortable) _row(ctx, Icons.sort, 'Change Sort Type', () => go(() => showSortSheet(context))),
        _row(ctx, Icons.web_asset, 'Change Post Layout', () => go(() => showLayoutSheet(context))),
        _row(ctx, Icons.search, 'Search', () => go(() => const FilterBar()._search(context))),
        _row(ctx, Icons.forum_outlined, 'Go to Subreddit', () => go(() => SourceBar.pickSub(context))),
        _row(ctx, Icons.face_outlined, 'Go to User', () => go(() => SourceBar.pickUser(context))),
        _row(ctx, Icons.history, 'Deep Search…', () => go(() => openDeepSearch())),
        _row(ctx, Icons.casino_outlined, 'Random', () => go(onRandom)),
        _row(ctx, h ? Icons.visibility_outlined : Icons.visibility_off_outlined, h ? 'Show Read Posts' : 'Hide Read Posts',
            () => hideRead.value = !hideRead.value,
            trailing: Switch(value: h, onChanged: (v) => hideRead.value = v)),
        _row(ctx, Icons.filter_alt_outlined, 'Filter Posts', () => go(() => showFilterSheet(context))),
        _row(ctx, Icons.arrow_upward, 'Go To Top', () => go(onTop)),
      ]),
    );
  });
}
