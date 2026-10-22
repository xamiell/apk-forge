import 'package:flutter/material.dart';

/// APK Forge's logo: the Android robot in the theme's primary color. The
/// window's header shows it, and `tool/app_icon.dart` draws the app icon
/// from it.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Icon(
    Icons.android_rounded,
    size: size,
    color: Theme.of(context).colorScheme.primary,
  );
}
