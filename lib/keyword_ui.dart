import 'package:flutter/material.dart';

import 'filters.dart';
import 'relevance.dart';
import 'source_bar.dart';

/// Keyword chips under the search box: each term with its weight. Tap to boost, x to remove.
class KeywordChips extends StatelessWidget {
  const KeywordChips({super.key});

  static String _label(QTerm t) {
    final s = t.words.length > 1 ? '"${t.text}"' : t.text;
    if (t.neg) return 'not $s';
    return t.weight == 1 ? s : '$s x${t.weight == t.weight.roundToDouble() ? t.weight.toInt() : t.weight}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([searchQuery, relevanceSort, currentSource, Rel.ready]),
        builder: (context, _) {
          final own = parseQuery(searchQuery.value);
          final fixed = Rel.sourceQuery();
          if (own.isEmpty && fixed.isEmpty) return const SizedBox.shrink();
          final cs = Theme.of(context).colorScheme;
          void set(List<QTerm> t) => searchQuery.value = own.withTerms(t).serialize();
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                FilterChip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Relevance'),
                  selected: relevanceSort.value,
                  onSelected: (b) => relevanceSort.value = b,
                ),
                for (final t in fixed.terms) Chip(visualDensity: VisualDensity.compact, label: Text(_label(t))),
                if (own.author != null) InputChip(visualDensity: VisualDensity.compact, label: Text('u/${own.author}'),
                    onDeleted: () => searchQuery.value = RQuery(own.terms, sub: own.sub).serialize()),
                if (own.sub != null) InputChip(visualDensity: VisualDensity.compact, label: Text('r/${own.sub}'),
                    onDeleted: () => searchQuery.value = RQuery(own.terms, author: own.author).serialize()),
                for (var i = 0; i < own.terms.length; i++)
                  InputChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(_label(own.terms[i])),
                    tooltip: own.terms[i].neg ? 'Excluded' : 'Tap to boost',
                    selected: own.terms[i].weight > 1,
                    onPressed: own.terms[i].neg
                        ? null
                        : () {
                            final t = [...own.terms];
                            final w = t[i].weight;
                            t[i] = t[i].copy(weight: w >= 3 ? 1 : w.floorToDouble() + 1);
                            set(t);
                          },
                    onDeleted: () => set([...own.terms]..removeAt(i)),
                  ),
              ]),
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 4),
                child: Text('"exact phrase"   word^2 boost   -word exclude   a OR b   u/name   r/sub',
                    style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant)),
              ),
            ]),
          );
        },
      );
}

/// Boost a word from the live query (long-press on highlighted text).
void showBoostSheet(BuildContext context) {
  final q = parseQuery(searchQuery.value);
  final pos = [for (var i = 0; i < q.terms.length; i++) if (!q.terms[i].neg) i];
  if (pos.isEmpty) return;
  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('Boost this word', style: TextStyle(fontWeight: FontWeight.bold))),
        for (final i in pos)
          ListTile(
            leading: const Icon(Icons.trending_up),
            title: Text(q.terms[i].text),
            trailing: Text('x${(q.terms[i].weight + 1).clamp(1, 5).toInt()}'),
            onTap: () {
              final t = [...q.terms];
              t[i] = t[i].copy(weight: (t[i].weight + 1).clamp(1, 5).toDouble());
              searchQuery.value = q.withTerms(t).serialize();
              Navigator.pop(ctx);
            },
          ),
      ]),
    ),
  );
}

/// Small 'why matched' line for a post while searching.
class WhyMatched extends StatelessWidget {
  final String id;
  const WhyMatched(this.id, {super.key});
  @override
  Widget build(BuildContext context) {
    final h = Rel.hitOf(id);
    if (h == null || h.fields == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text('Matched in ${h.why}', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.primary)),
    );
  }
}
