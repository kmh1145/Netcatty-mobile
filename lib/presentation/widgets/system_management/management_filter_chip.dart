import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';

class ManagementFilterChip extends StatelessWidget {
  const ManagementFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => ChoiceChip(
        label: LText(label),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onSelected(),
      );
}
