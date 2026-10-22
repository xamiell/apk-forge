// Draws the app icon from the app's logo (lib/ui/app_logo.dart) and the dark
// theme, and writes macOS's sizes. Run it again after a change to either:
//
//   flutter test tool/app_icon.dart
//
// It runs as a widget test because that's where Flutter can draw off screen.
// macOS caches the icon of an app it has already seen: if a new build still
// shows the old one, `touch` the .app and launch it again.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:apk_forge/ui/app_logo.dart';
import 'package:apk_forge/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _macosFolder = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';
const _macosSizes = [16, 32, 64, 128, 256, 512, 1024];

/// The canvas the icon is drawn on; each size is this one scaled.
const _canvas = 1024.0;

void main() {
  testWidgets('draws the macOS app icon', (tester) async {
    await tester.runAsync(_loadIconFont);
    tester.view.physicalSize = const Size.square(_canvas);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boundary = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: buildTheme(Brightness.dark),
          child: RepaintBoundary(key: boundary, child: const _MacosIcon()),
        ),
      ),
    );

    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    for (final size in _macosSizes) {
      final png = await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: size / _canvas);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return bytes!.buffer.asUint8List();
      });
      File('$_macosFolder/app_icon_$size.png').writeAsBytesSync(png!);
    }
  });
}

/// Widget tests draw icons with a placeholder font unless the real one is
/// loaded.
Future<void> _loadIconFont() async {
  final font = rootBundle.load('fonts/MaterialIcons-Regular.otf');
  await (FontLoader('MaterialIcons')..addFont(font)).load();
}

/// The logo on a dark rounded square, on Apple's grid for macOS icons: an
/// 824 pt square with 185.4 pt corners in the middle of the 1024 pt canvas,
/// which leaves room for its shadow.
class _MacosIcon extends StatelessWidget {
  const _MacosIcon();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(185.4),
    );
    return SizedBox.square(
      dimension: _canvas,
      child: Padding(
        padding: const EdgeInsets.all(100),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // A shape's own shadow comes out unblurred off screen.
            Transform.translate(
              offset: const Offset(0, 12),
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: shape,
                    color: const Color(0x4D000000),
                  ),
                ),
              ),
            ),
            DecoratedBox(
              decoration: ShapeDecoration(
                shape: shape,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    scheme.surfaceContainerHigh,
                    scheme.surfaceContainerLowest,
                  ],
                ),
              ),
              child: const Center(child: AppLogo(size: 600)),
            ),
          ],
        ),
      ),
    );
  }
}
