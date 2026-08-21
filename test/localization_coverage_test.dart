import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';

void main() {
  test('every Chinese source message has an English rendering', () {
    NetcattyLocalizations.use('en');
    final missing = <String>{};
    final literal = RegExp(r'''(['"])(.*?[\u4e00-\u9fff].*?)\1''');
    final han = RegExp(r'[\u4e00-\u9fff]');
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.contains(
          '${Platform.pathSeparator}localization${Platform.pathSeparator}')) {
        continue;
      }
      for (final line in entity.readAsLinesSync()) {
        for (final match in literal.allMatches(line)) {
          final source = match.group(2)!;
          final translated = NetcattyLocalizations.text(source);
          if (han.hasMatch(translated)) missing.add('$source -> $translated');
        }
      }
    }
    final details = missing.toList()..sort();
    expect(missing, isEmpty, reason: details.join('\n'));
  });
}
