import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/models/settings.dart';

Alignment resolveCustomBackgroundAlignment(String value) => switch (value) {
      'topLeft' => Alignment.topLeft,
      'topCenter' => Alignment.topCenter,
      'topRight' => Alignment.topRight,
      'centerLeft' => Alignment.centerLeft,
      'centerRight' => Alignment.centerRight,
      'bottomLeft' => Alignment.bottomLeft,
      'bottomCenter' => Alignment.bottomCenter,
      'bottomRight' => Alignment.bottomRight,
      _ => Alignment.center,
    };

bool hasCustomBackground(AppSettings settings) =>
    settings.customBackgroundEnabled &&
    settings.customBackgroundPath.trim().isNotEmpty;

bool hasGlobalCustomBackground(AppSettings settings) =>
    hasCustomBackground(settings) && settings.customBackgroundScope == 'global';

bool customBackgroundAppliesToTab(AppSettings settings, int tabIndex) =>
    hasCustomBackground(settings) &&
    (settings.customBackgroundScope == 'global' || tabIndex == 1);

class CustomBackgroundImage extends StatelessWidget {
  const CustomBackgroundImage({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    if (!hasCustomBackground(settings)) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: settings.customBackgroundOpacity,
          child: Image.file(
            File(settings.customBackgroundPath),
            fit: BoxFit.cover,
            alignment: resolveCustomBackgroundAlignment(
              settings.customBackgroundAlignment,
            ),
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
