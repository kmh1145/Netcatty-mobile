import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/presentation/widgets/system_management/management_filter_chip.dart';

void main() {
  testWidgets('选中的管理筛选标签仅使用颜色且不显示勾号', (tester) async {
    var tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManagementFilterChip(
            label: '全部',
            selected: true,
            onSelected: () => tapped = true,
          ),
        ),
      ),
    );

    final chip = tester.widget<ChoiceChip>(find.byType(ChoiceChip));
    expect(chip.selected, isTrue);
    expect(chip.showCheckmark, isFalse);

    await tester.tap(find.byType(ChoiceChip));
    expect(tapped, isTrue);
  });
}
