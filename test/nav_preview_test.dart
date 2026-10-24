import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hobee/nav_bar.dart';

Widget frame(double inset, GlobalKey k) => RepaintBoundary(
      key: k,
      child: MediaQuery(
        data: MediaQueryData(size: const Size(400, 200), padding: EdgeInsets.only(bottom: inset), viewPadding: EdgeInsets.only(bottom: inset)),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            extendBody: true,
            backgroundColor: const Color(0xFF223344),
            body: const SizedBox.expand(),
            bottomNavigationBar: HobeeNavBar(selected: 0, accent: const Color(0xFFE53935), onSelect: (_) {}),
          ),
        ),
      ),
    );

void main() {
  for (final inset in [24.0, 48.0]) {
    testWidgets('nav pill centered, inset $inset', (t) async {
      t.view.physicalSize = const Size(400, 200);
      t.view.devicePixelRatio = 1;
      final k = GlobalKey();
      await t.pumpWidget(frame(inset, k));
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull);
      final pill = t.getRect(find.byWidgetPredicate((w) => w is SizedBox && w.height == 56));
      final icon = t.getRect(find.byIcon(Icons.home));
      expect(pill.height, 56);
      expect(200 - pill.bottom, closeTo(inset + 8, 0.5));
      expect((icon.center.dy - pill.center.dy).abs(), lessThan(1.5));
      expect(find.text('Home'), findsNothing); // icons only
      expect(find.byTooltip('Home'), findsOneWidget);
      expect(find.bySemanticsLabel('Settings'), findsOneWidget);
      expect((pill.center.dx - 200).abs(), lessThan(1.5));
      // ignore: avoid_print
      print('inset $inset pill=$pill icon=$icon');
      await t.runAsync(() async {
        final img = await (k.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        File('build/nav-$inset.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    });
  }
}
