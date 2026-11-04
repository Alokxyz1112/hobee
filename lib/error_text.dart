/// Short, readable error text for the Technical details panel.
library;

final _htmlish = RegExp(r'<\s*(!doctype|html|head|body|div|style|script|meta|title)\b', caseSensitive: false);
final _iso = RegExp(r'\b(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)');

bool looksLikeHtml(String s) => _htmlish.hasMatch(s);

/// A response body worth showing: HTML pages (block pages, bot checks) are left out, the rest is trimmed.
String bodySnippet(String b) {
  if (looksLikeHtml(b)) return '';
  final t = b.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 200 ? '${t.substring(0, 200)}...' : t;
}

/// '9:52 AM' style local time.
String shortTime(DateTime t) {
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
}

/// One clean line per fact: no HTML, no raw timestamps, no stray indentation.
String cleanDetail(String raw) {
  final out = <String>[];
  for (var line in raw.split('\n')) {
    line = line.trim();
    if (line.isEmpty) continue;
    final h = _htmlish.firstMatch(line);
    if (h != null) line = line.substring(0, h.start).trim();
    if (line.isEmpty) continue;
    line = line.replaceAllMapped(_iso, (m) {
      final d = DateTime.tryParse(m[1]!);
      return d == null ? m[1]! : shortTime(d);
    });
    out.add(line.length > 240 ? '${line.substring(0, 240)}...' : line);
  }
  return out.join('\n');
}

/// "Label: detail", with multi line details (one per host) starting on their own lines.
String detailLine(String label, String raw) {
  final d = cleanDetail(raw);
  if (d.isEmpty) return label;
  final dup = d.toLowerCase().startsWith('${label.toLowerCase()}:');
  if (dup) return d;
  return d.contains('\n') ? '$label:\n$d' : '$label: $d';
}
