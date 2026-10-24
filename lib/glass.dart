import 'dart:ui';
import 'package:flutter/material.dart';

const glassSigma = 22.0;
const _tint = Color(0xFFE53935);

bool _dark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;

Color glassFill(BuildContext c) => _dark(c) ? const Color(0xFF141414).withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.4);
Color glassEdge(BuildContext c) => Colors.white.withValues(alpha: _dark(c) ? 0.16 : 0.75);

/// Translucent fill with a faint red tint, top-left lighter.
Gradient glassGradient(BuildContext c) {
  final d = _dark(c);
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: d
        ? [Colors.white.withValues(alpha: 0.10), _tint.withValues(alpha: 0.10), Colors.black.withValues(alpha: 0.30)]
        : [Colors.white.withValues(alpha: 0.45), Colors.white.withValues(alpha: 0.35), _tint.withValues(alpha: 0.10)],
  );
}

/// Soft page background so the glass reads even on empty screens.
BoxDecoration pageBackground(BuildContext c) => BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: _dark(c)
            ? const [Color(0xFF121212), Color(0xFF1E1214), Color(0xFF2A1215)]
            : const [Color(0xFFFFFBF8), Color(0xFFFFF1F1), Color(0xFFFFE3E6)],
      ),
    );

/// Padding for scrollables under a blurred app bar and above the floating nav pill.
/// The Scaffold (extendBodyBehindAppBar / extendBody) already folds bar heights into MediaQuery padding.
EdgeInsets bodyPadding(BuildContext c, {double h = 16, double v = 16, bool appBar = true}) {
  final p = MediaQuery.paddingOf(c);
  final top = appBar && p.top < kToolbarHeight ? p.top + kToolbarHeight : p.top;
  return EdgeInsets.fromLTRB(h, top + v, h, p.bottom + v);
}

/// Frosted panel: backdrop blur + translucent tinted gradient + 1px highlight border + soft shadow.
class Glass extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;
  final Color? fill;
  final Border? border;
  final bool shadow;
  const Glass({super.key, required this.child, this.radius = BorderRadius.zero, this.fill, this.border, this.shadow = false});
  @override
  Widget build(BuildContext context) {
    final panel = ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: glassSigma, sigmaY: glassSigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            gradient: fill == null ? glassGradient(context) : null,
            borderRadius: radius,
            border: border ?? Border.all(color: glassEdge(context), width: 1),
          ),
          child: child,
        ),
      ),
    );
    if (!shadow) return panel;
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: [
        BoxShadow(color: Colors.black.withValues(alpha: _dark(context) ? 0.35 : 0.10), blurRadius: 24, offset: const Offset(0, 8)),
        BoxShadow(color: _tint.withValues(alpha: 0.08), blurRadius: 12, spreadRadius: -2),
      ]),
      child: panel,
    );
  }
}

/// AppBar flexibleSpace: full-bleed blurred bar with a hairline bottom highlight.
class GlassBar extends StatelessWidget {
  const GlassBar({super.key});
  @override
  Widget build(BuildContext context) => Glass(
        border: Border(bottom: BorderSide(color: glassEdge(context), width: 1)),
        child: const SizedBox.expand(),
      );
}
