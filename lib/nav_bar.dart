import 'package:flutter/material.dart';
import 'glass.dart';

/// Compact floating glass pill. The system bottom inset is applied only OUTSIDE the pill as margin.
class HobeeNavBar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  final Color accent;
  const HobeeNavBar({super.key, required this.selected, required this.onSelect, required this.accent});

  static const height = 56.0;
  static const _items = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.manage_search_outlined, Icons.manage_search, 'Deep'),
    (Icons.search_outlined, Icons.search, 'Search'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, inset + 8),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Glass(
            radius: BorderRadius.circular(height / 2),
            shadow: true,
            child: SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(children: [
                  for (var i = 0; i < _items.length; i++)
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: i == selected,
                        label: _items[i].$3,
                        child: InkWell(
                          customBorder: const StadiumBorder(),
                          onTap: () => onSelect(i),
                          child: Center(child: _tile(i, cs)),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(int i, ColorScheme cs) {
    final sel = i == selected;
    final (off, on, label) = _items[i];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: 40,
      padding: EdgeInsets.symmetric(horizontal: sel ? 12 : 8),
      decoration: ShapeDecoration(shape: const StadiumBorder(), color: sel ? accent.withValues(alpha: 0.16) : Colors.transparent),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(sel ? on : off, size: 22, color: sel ? accent : cs.onSurfaceVariant),
        if (sel) ...[
          const SizedBox(width: 6),
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false,
              style: TextStyle(fontSize: 12, height: 1.0, fontWeight: FontWeight.w600, color: accent))),
        ],
      ]),
    );
  }
}
