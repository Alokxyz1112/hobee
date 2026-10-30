import 'dart:math' as math;

import 'find.dart' show fold, withinOneEdit;

/// Relevance search: query syntax, entity matching and BM25-style ranking.
///
/// Syntax: words are ANDed; "exact phrase"; word^2 boosts; -word excludes; a OR b;
/// u/name or @name limits to an author; r/name limits to a subreddit.

class QTerm {
  final List<String> words; // folded; more than one = phrase or entity
  final double weight;
  final bool neg, quoted;
  final int group; // terms in the same group are ORed
  const QTerm(this.words, {this.weight = 1, this.neg = false, this.quoted = false, this.group = 0});
  String get text => words.join(' ');
  QTerm copy({double? weight}) => QTerm(words, weight: weight ?? this.weight, neg: neg, quoted: quoted, group: group);
}

class RQuery {
  final List<QTerm> terms;
  final String? author, sub;
  const RQuery(this.terms, {this.author, this.sub});
  static const empty = RQuery([]);
  Iterable<QTerm> get pos => terms.where((t) => !t.neg);
  bool get isEmpty => terms.isEmpty && author == null && sub == null;
  bool get hasOr => pos.map((t) => t.group).toSet().length < pos.length;
  int get groups => pos.map((t) => t.group).toSet().length;

  /// Folded strings to highlight.
  List<String> get highlight => [for (final t in pos) t.text];

  /// Plain words for a server title search (null when the query needs local ranking only).
  String? get serverTitle {
    if (hasOr || pos.isEmpty) return null;
    return pos.map((t) => t.text).join(' ');
  }

  /// Back to text, after boosting or removing a term from the chips row.
  String serialize() {
    final b = <String>[];
    if (author != null) b.add('u/$author');
    if (sub != null) b.add('r/$sub');
    QTerm? prev;
    for (final t in terms) {
      if (prev != null && !t.neg && !prev.neg && prev.group == t.group) b.add('OR');
      var s = t.words.length > 1 || t.quoted ? '"${t.text}"' : t.text;
      if (t.weight != 1) s += '^${t.weight == t.weight.roundToDouble() ? t.weight.toInt() : t.weight}';
      b.add(t.neg ? '-$s' : s);
      prev = t;
    }
    return b.join(' ');
  }

  RQuery withTerms(List<QTerm> t) => RQuery(t, author: author, sub: sub);
}

final _split = RegExp(r'[^a-z0-9]+');
List<String> _words(String s) => fold(s).replaceAll(RegExp("['\u2019]s\\b"), '').split(_split).where((w) => w.isNotEmpty).toList();

RQuery parseQuery(String q) {
  final terms = <QTerm>[];
  String? author, sub;
  var group = -1;
  var orNext = false;
  for (final m in RegExp(r'(-?)"([^"]*)"(?:\^(\d+(?:\.\d+)?))?|(\S+)').allMatches(q)) {
    var neg = m.group(1) == '-';
    String body;
    double w = 1;
    var quoted = m.group(2) != null;
    if (quoted) {
      body = m.group(2)!;
      if (m.group(3) != null) w = double.tryParse(m.group(3)!) ?? 1;
    } else {
      body = m.group(4)!;
      if (body == 'OR' || body == '|') { orNext = true; continue; }
      final low = body.toLowerCase();
      final um = RegExp(r'^(?:@|/?u/)([a-z0-9_-]{2,})$').firstMatch(low);
      if (um != null) { author = um.group(1); continue; }
      final rm = RegExp(r'^/?r/([a-z0-9_]{2,})$').firstMatch(low);
      if (rm != null) { sub = rm.group(1); continue; }
      if (body.startsWith('-') && body.length > 1) { neg = true; body = body.substring(1); }
      final bm = RegExp(r'^(.+)\^(\d+(?:\.\d+)?)$').firstMatch(body);
      if (bm != null) { body = bm.group(1)!; w = double.tryParse(bm.group(2)!) ?? 1; }
    }
    final ws = _words(body);
    if (ws.isEmpty) continue;
    w = w.clamp(0.1, 10).toDouble();
    if (!(orNext && !neg && group >= 0)) group++;
    orNext = false;
    terms.add(QTerm(ws, weight: w, neg: neg, quoted: quoted, group: neg ? -1 : group));
  }
  return RQuery(terms, author: author, sub: sub);
}

// ---------- documents ----------

const fieldNames = ['title', 'flair', 'text', 'link', 'subreddit'];
const _fieldW = [3.0, 2.0, 1.0, 1.5, 1.0];

/// Plain data so ranking can run in an isolate.
class RDoc {
  final List<String> fields; // title, flair, selftext, url+domain, subreddit
  final String author;
  final int created, score;
  const RDoc(this.fields, this.author, this.created, this.score);
}

class RHit {
  final double score;
  final int fields; // bit per field that matched
  const RHit(this.score, this.fields);
  String get why => [for (var i = 0; i < fieldNames.length; i++) if (fields & (1 << i) != 0) fieldNames[i]].join(', ');
}

String _stem(String w) {
  if (w.length > 4 && w.endsWith('ies')) return '${w.substring(0, w.length - 3)}y';
  if (w.length > 4 && (w.endsWith('ses') || w.endsWith('xes') || w.endsWith('ches') || w.endsWith('shes'))) return w.substring(0, w.length - 2);
  if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) return w.substring(0, w.length - 1);
  return w;
}

/// How well doc word [t] matches query word [q]: whole word 1, plural variant 0.7,
/// one typo (words over 4 letters) 0.6, prefix 0.45, else 0.
double wordLevel(String t, String q, {bool typo = true}) {
  if (t == q) return 1;
  if (_stem(t) == _stem(q)) return 0.7;
  if (typo && q.length > 4 && (t.length - q.length).abs() <= 1 && withinOneEdit(t, q)) return 0.6;
  if (q.length >= 3 && t.length > q.length && t.startsWith(q)) return 0.45;
  return 0;
}

/// Occurrences of a term in a token list: (start index, level). Hyphen/space variants match
/// because both sides are split into words; 'spiderman' also matches 'spider man'.
List<(int, double)> _occ(List<String> toks, QTerm t, {bool typo = true}) {
  final out = <(int, double)>[];
  final ws = t.words;
  for (var i = 0; i < toks.length; i++) {
    if (ws.length == 1) {
      var l = wordLevel(toks[i], ws[0], typo: typo);
      if (l == 0 && i + 1 < toks.length && toks[i] + toks[i + 1] == ws[0]) l = 0.9;
      if (l > 0) out.add((i, l));
      continue;
    }
    if (i + ws.length <= toks.length) {
      var l = 1.0;
      for (var k = 0; k < ws.length && l > 0; k++) {
        l = math.min(l, wordLevel(toks[i + k], ws[k], typo: typo && !t.quoted));
      }
      if (t.quoted && l < 0.7) l = 0;
      if (l > 0) { out.add((i, l)); continue; }
    }
    // 'spider-man' typed as one word in the doc.
    if (toks[i] == ws.join()) out.add((i, 0.9));
  }
  return out;
}

const _k1 = 1.2, _b = 0.4;

/// Rank [docs] for [q]; returns a hit per matching doc index (others are missing).
Map<int, RHit> rankDocs(List<RDoc> docs, RQuery q, {int? now}) {
  final out = <int, RHit>{};
  if (docs.isEmpty) return out;
  final pos = q.pos.toList();
  final neg = q.terms.where((t) => t.neg).toList();
  final toks = [for (final d in docs) [for (final f in d.fields) _words(f)]];
  final nf = fieldNames.length;
  final avg = List<double>.filled(nf, 1);
  for (var f = 0; f < nf; f++) {
    var s = 0;
    for (final t in toks) { s += t[f].length; }
    avg[f] = math.max(1, s / docs.length);
  }
  // Pass 1: term frequencies per doc and field, plus document frequency.
  final tf = List.generate(docs.length, (_) => List.generate(pos.length, (_) => List<double>.filled(nf, 0)));
  final firstPos = List.generate(docs.length, (_) => List<int>.filled(pos.length, -1));
  final df = List<int>.filled(pos.length, 0);
  final keep = List<bool>.filled(docs.length, true);
  for (var i = 0; i < docs.length; i++) {
    final d = docs[i];
    if (q.author != null && d.author.toLowerCase() != q.author) { keep[i] = false; continue; }
    if (q.sub != null && fold(d.fields[4]) != q.sub) { keep[i] = false; continue; }
    for (final n in neg) {
      if (toks[i].any((f) => _occ(f, n, typo: false).isNotEmpty)) { keep[i] = false; break; }
    }
    if (!keep[i]) continue;
    for (var t = 0; t < pos.length; t++) {
      var any = false;
      for (var f = 0; f < nf; f++) {
        final o = _occ(toks[i][f], pos[t]);
        if (o.isEmpty) continue;
        any = true;
        tf[i][t][f] = o.fold(0.0, (a, x) => a + x.$2);
        if (f == 0) firstPos[i][t] = o.first.$1;
      }
      if (any) df[t]++;
    }
  }
  final n = docs.length;
  final groups = q.groups;
  var newest = 0, oldest = 1 << 62;
  for (final d in docs) { newest = math.max(newest, d.created); oldest = math.min(oldest, d.created); }
  final span = math.max(1, newest - oldest);
  for (var i = 0; i < n; i++) {
    if (!keep[i]) continue;
    var s = 0.0;
    var fields = 0;
    final hitGroups = <int>{};
    var hitTerms = 0;
    for (var t = 0; t < pos.length; t++) {
      var ts = 0.0;
      for (var f = 0; f < nf; f++) {
        final x = tf[i][t][f];
        if (x == 0) continue;
        fields |= 1 << f;
        final len = toks[i][f].length;
        ts += _fieldW[f] * x * (_k1 + 1) / (x + _k1 * (1 - _b + _b * len / avg[f]));
      }
      if (ts == 0) continue;
      hitTerms++;
      hitGroups.add(pos[t].group);
      final idf = math.log(1 + (n - df[t] + 0.5) / (df[t] + 0.5));
      var termScore = (0.3 + idf) * pos[t].weight * ts;
      if (pos[t].words.length > 1 && tf[i][t][0] > 0) termScore *= 1.5; // phrase/entity in title
      s += termScore;
    }
    if (pos.isNotEmpty && hitGroups.length < groups) continue; // every AND group must match
    if (pos.isEmpty && q.author == null && q.sub == null && neg.isEmpty) continue;
    if (pos.length > 1 && hitTerms == pos.length) s *= 1.3; // all terms
    // Proximity: unquoted words that sit next to each other in the title read as one entity.
    if (pos.length > 1) {
      final p = [for (var t = 0; t < pos.length; t++) firstPos[i][t]];
      if (!p.contains(-1)) {
        final span = p.reduce(math.max) - p.reduce(math.min) + 1;
        final need = pos.fold(0, (a, t) => a + t.words.length);
        s *= 1 + 0.6 * need / math.max(need, span);
        var inOrder = true;
        for (var k = 1; k < p.length; k++) { if (p[k] != p[k - 1] + pos[k - 1].words.length) inOrder = false; }
        if (inOrder) s *= 1.4;
      }
    }
    // Light tiebreak: newer and higher scored posts first among equals.
    final d = docs[i];
    s += 0.05 * (d.created - oldest) / span + 0.02 * math.log(1 + math.max(0, d.score)) / 10;
    out[i] = RHit(s, fields);
  }
  return out;
}

/// Isolate entry point.
Map<int, RHit> rankJob((List<RDoc>, String) job) => rankDocs(job.$1, parseQuery(job.$2));
