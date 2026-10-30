import 'models.dart';

/// Instant search helpers: folded haystacks per post, multi-word AND, light typo tolerance,
/// plus the extra post kinds (links, documents) and archive status.

const _fold = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', 'ă': 'a', 'ą': 'a', 'æ': 'ae',
  'ç': 'c', 'ć': 'c', 'č': 'c', 'ď': 'd', 'đ': 'd', 'ð': 'd',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ė': 'e', 'ę': 'e', 'ě': 'e',
  'ğ': 'g', 'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'į': 'i', 'ı': 'i',
  'ł': 'l', 'ľ': 'l', 'ñ': 'n', 'ń': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o', 'ő': 'o', 'œ': 'oe',
  'ř': 'r', 'ś': 's', 'š': 's', 'ş': 's', 'ș': 's', 'ß': 'ss', 'ť': 't', 'ț': 't', 'þ': 'th',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ů': 'u', 'ű': 'u', 'ų': 'u',
  'ý': 'y', 'ÿ': 'y', 'ź': 'z', 'ż': 'z', 'ž': 'z',
};

/// Lowercase and strip accents so 'Café' matches 'cafe'. Length may change only for ligatures.
String fold(String s) {
  final l = s.toLowerCase();
  var plain = true;
  for (final c in l.codeUnits) {
    if (c > 127) { plain = false; break; }
  }
  if (plain) return l;
  final b = StringBuffer();
  for (final ch in l.split('')) {
    b.write(_fold[ch] ?? ch);
  }
  return b.toString();
}

/// Search terms from a query: folded, split on spaces, empty ones dropped. "quoted phrases" stay together.
List<String> queryTerms(String q) {
  final out = <String>[];
  for (final m in RegExp(r'"([^"]+)"|(\S+)').allMatches(fold(q))) {
    final t = (m.group(1) ?? m.group(2) ?? '').trim();
    if (t.isNotEmpty) out.add(t);
  }
  return out;
}

String _s(Object? o) => o is String ? o : '';

final _hay = Expando<String>();
final _words = Expando<List<String>>();

/// Everything searchable about a post, folded once and cached on the post.
String haystack(Post p) => _hay[p] ??= fold([
      p.title,
      _s(p.raw['selftext']),
      'r/${p.subreddit}',
      'u/${p.author}',
      _s(p.raw['link_flair_text']),
      _s(p.raw['author_flair_text']),
      _s(p.raw['domain']),
      _s(p.raw['url_overridden_by_dest'] ?? p.raw['url']),
    ].join('\n'));

List<String> _wordsOf(Post p) => _words[p] ??= haystack(p).split(RegExp(r'[^a-z0-9]+')).where((w) => w.length >= 3).toSet().toList();

/// True when every term is found (substring), or for longer words, a word one typo away.
bool textMatches(Post p, List<String> terms) {
  if (terms.isEmpty) return true;
  final h = haystack(p);
  for (final t in terms) {
    if (h.contains(t)) continue;
    if (t.length < 4 || t.contains(' ')) return false;
    if (!_wordsOf(p).any((w) => (w.length - t.length).abs() <= 1 && withinOneEdit(w, t))) return false;
  }
  return true;
}

/// Levenshtein distance <= 1 (insert, delete, substitute) or one adjacent swap.
bool withinOneEdit(String a, String b) {
  if (a == b) return true;
  final la = a.length, lb = b.length;
  if ((la - lb).abs() > 1) return false;
  var i = 0;
  while (i < la && i < lb && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  if (la == lb) {
    if (a.substring(i + 1) == b.substring(i + 1)) return true;
    return i + 1 < la && a[i] == b[i + 1] && a[i + 1] == b[i] && a.substring(i + 2) == b.substring(i + 2);
  }
  return la > lb ? a.substring(i + 1) == b.substring(i) : a.substring(i) == b.substring(i + 1);
}

/// Ranges in [text] that match any of [terms] (accent-insensitive), merged and sorted.
List<(int, int)> matchRanges(String text, List<String> terms) {
  if (terms.isEmpty || text.isEmpty) return const [];
  // Fold char by char so indexes line up with the original text.
  final f = StringBuffer();
  final map = <int>[];
  for (var i = 0; i < text.length; i++) {
    final c = fold(text[i]);
    for (var k = 0; k < c.length; k++) {
      map.add(i);
    }
    f.write(c);
  }
  final ft = f.toString();
  final r = <(int, int)>[];
  for (final t in terms) {
    var at = ft.indexOf(t);
    while (at >= 0) {
      r.add((map[at], map[at + t.length - 1] + 1));
      at = ft.indexOf(t, at + t.length);
    }
  }
  if (r.isEmpty) return const [];
  r.sort((a, b) => a.$1.compareTo(b.$1));
  final out = <(int, int)>[r.first];
  for (final x in r.skip(1)) {
    final l = out.last;
    if (x.$1 <= l.$2) {
      out[out.length - 1] = (l.$1, x.$2 > l.$2 ? x.$2 : l.$2);
    } else {
      out.add(x);
    }
  }
  return out;
}

// ---- kinds ----

final _docRe = RegExp(
    r'\.(pdf|docx?|pptx?|xlsx?|odt|ods|odp|rtf|txt|csv|epub|md)(\?|#|$)|docs\.google\.com|drive\.google\.com|dropbox\.com|onedrive\.live\.com|1drv\.ms|sharepoint\.com|scribd\.com|notion\.(so|site)|arxiv\.org/(abs|pdf)',
    caseSensitive: false);

String linkUrl(Post p) => _s(p.raw['url_overridden_by_dest'] ?? p.raw['url']);

bool isSelfPost(Post p) {
  if (p.raw['is_self'] == true) return true;
  final u = linkUrl(p);
  return u.isEmpty || u.contains('/comments/${p.id}');
}

bool isDocument(Post p) {
  if (p.media.isNotEmpty) return false;
  final u = linkUrl(p);
  if (!isSelfPost(p) && _docRe.hasMatch(u)) return true;
  // Text posts that share a document link in the body count too.
  return _docRe.hasMatch(_s(p.raw['selftext']));
}

bool isLink(Post p) => p.media.isEmpty && !isSelfPost(p) && !isDocument(p);

enum PostStatus { live, archive, removed }

const statusLabels = {PostStatus.live: 'Live', PostStatus.archive: 'Archive', PostStatus.removed: 'Removed'};

PostStatus statusOf(Post p) {
  final r = p.raw;
  if (r['_hobee_live'] == true) return PostStatus.live;
  if (r['removed_by_category'] != null || r['author'] == '[deleted]' || r['selftext'] == '[removed]' || r['selftext'] == '[deleted]') {
    return PostStatus.removed;
  }
  return PostStatus.archive;
}

// ---- photo similarity ----

/// Same thresholds as the dupe finder: <= 3 bits apart is the same picture, <= 10 looks alike.
const exactBits = 3;
const similarBits = 10;

String matchLabel(int bits) => bits <= exactBits ? 'Exact' : 'Similar';
