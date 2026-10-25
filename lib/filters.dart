import 'clean.dart';
import 'package:flutter/material.dart';
import 'glass.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'db.dart';
import 'models.dart';
import 'source_bar.dart';
import 'nav.dart';

enum MediaFilter { all, images, videos, galleries, text }

const mediaFilterLabels = {
  MediaFilter.all: 'All',
  MediaFilter.images: 'Images',
  MediaFilter.videos: 'Videos',
  MediaFilter.galleries: 'Galleries',
  MediaFilter.text: 'Text',
};

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
final hideGone = ValueNotifier<bool>(false);
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
final viewFilters = Listenable.merge([mediaFilter, dateRange, searchQuery, hideRead, hideDupes, hideDupesDeep, hideGone]);

Future<void> loadFilterPrefs() async {
  final sp = await SharedPreferences.getInstance();
  mediaFilter.value = MediaFilter.values[(sp.getInt('mediaFilter') ?? 0).clamp(0, MediaFilter.values.length - 1)];
  _sp = sp;
  subSort.value = sp.getString('subSort') ?? 'new';
  hideRead.value = sp.getBool('hideRead') ?? false;
  originalQuality.value = sp.getBool('originalQuality') ?? true;
  cleanDownloads.value = sp.getBool('cleanDownloads') ?? true;
  cleanDownloads.addListener(() => sp.setBool('cleanDownloads', cleanDownloads.value));
  originalQuality.addListener(() => sp.setBool('originalQuality', originalQuality.value));
  hideDupes.value = sp.getBool('hideDupes') ?? false;
  hideDupesDeep.value = sp.getBool('hideDupesDeep') ?? true;
  hideGone.value = sp.getBool('hideGone') ?? false;
  hideGone.addListener(() => sp.setBool('hideGone', hideGone.value));
  hideDupes.addListener(() => sp.setBool('hideDupes', hideDupes.value));
  hideDupesDeep.addListener(() => sp.setBool('hideDupesDeep', hideDupesDeep.value));
  readIds.addAll(sp.getStringList('readIds') ?? []);
  postLayout.value = PostLayout.values[(sp.getInt('postLayout') ?? 3).clamp(0, 3)];
  hideRead.addListener(() => sp.setBool('hideRead', hideRead.value));
  postLayout.addListener(() => sp.setInt('postLayout', postLayout.value.index));
  mediaFilter.addListener(() => sp.setInt('mediaFilter', mediaFilter.value.index));
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

bool matches(Post p) {
  final f = mediaFilter.value;
  if (f == MediaFilter.text) {
    if (p.media.isNotEmpty) return false;
  } else {
    if (p.media.isEmpty) return false;
    if (f != MediaFilter.all && kindOf(p) != f) return false;
  }
  if (hideRead.value && readIds.contains(p.id)) return false;
  final r = dateRange.value;
  if (r != null) {
    final d = p.date.toLocal();
    if (d.isBefore(r.start) || !d.isBefore(r.end.add(const Duration(days: 1)))) return false;
  }
  final q = searchQuery.value.trim().toLowerCase();
  if (q.isNotEmpty && !p.title.toLowerCase().contains(q) && !p.subreddit.toLowerCase().contains(q)) return false;
  return true;
}

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
      listenable: Listenable.merge([viewFilters, subSort, currentSource]),
      builder: (_, _) {
        final r = dateRange.value;
        final q = searchQuery.value;
        final isSub = sortable;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            Glass(
              radius: BorderRadius.circular(20),
              child: SegmentedButton<MediaFilter>(
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? cs.primary.withValues(alpha: 0.22) : Colors.transparent),
                side: WidgetStatePropertyAll(BorderSide(color: glassEdge(context))),
              ),
              segments: [
                for (final f in MediaFilter.values) ButtonSegment(value: f, label: Text(mediaFilterLabels[f]!)),
              ],
              selected: {mediaFilter.value},
              onSelectionChanged: (s) => mediaFilter.value = s.first,
            ),
            ),
            const SizedBox(width: 6),
            if (r != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InputChip(
                  avatar: Icon(Icons.date_range, size: 16, color: cs.primary),
                  label: Text('${_d(r.start)} to ${_d(r.end)}'),
                  onPressed: () => _pickDate(context),
                  onDeleted: () => dateRange.value = null,
                ),
              )
            else
              IconButton(icon: const Icon(Icons.date_range), tooltip: 'Filter by date', visualDensity: VisualDensity.compact, onPressed: () => _pickDate(context)),
            if (q.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InputChip(
                  avatar: Icon(Icons.search, size: 16, color: cs.primary),
                  label: Text('"$q"'),
                  onPressed: () => _search(context),
                  onDeleted: () => searchQuery.value = '',
                ),
              )
            else
              IconButton(icon: const Icon(Icons.search), tooltip: 'Search', visualDensity: VisualDensity.compact, onPressed: () => _search(context)),
            if (isSub)
              ActionChip(
                avatar: Icon(Icons.sort, size: 16, color: cs.primary),
                label: Text(sortLabel(subSort.value)),
                onPressed: () => _sort(context),
              ),
          ]),
        );
      },
    );
  }
}

/// AppBar bottom combining source tabs and filter row.
class SourceAndFilterBar extends StatelessWidget implements PreferredSizeWidget {
  final bool sources;
  const SourceAndFilterBar({super.key, this.sources = true});
  @override
  Size get preferredSize => Size.fromHeight(sources ? 100 : 52);
  @override
  Widget build(BuildContext context) => Column(children: [
        if (sources) const SizedBox(height: 48, child: SourceBar()),
        const SizedBox(height: 52, child: FilterBar()),
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
          for (final (f, i) in [
            (MediaFilter.all, Icons.all_inclusive),
            (MediaFilter.images, Icons.image_outlined),
            (MediaFilter.videos, Icons.play_circle_outline),
            (MediaFilter.galleries, Icons.collections_outlined),
            (MediaFilter.text, Icons.notes),
          ])
            _row(ctx, i, mediaFilterLabels[f]!, () => mediaFilter.value = f,
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
