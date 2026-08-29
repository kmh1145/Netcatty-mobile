import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';

void main() {
  test('legacy single AI model migrates into the model list', () {
    final settings = AppSettings.fromJson({
      'aiModel': 'custom-model',
    });

    expect(settings.aiModel, 'custom-model');
    expect(settings.aiModels, ['custom-model']);
    expect(settings.aiIncludeTerminalContext, isFalse);
    expect(settings.aiReasoningEffort, defaultAiReasoningEffort);
  });

  test('AI model list is normalized and privacy choice round-trips', () {
    final settings = AppSettings.fromJson({
      'aiModel': 'model-b',
      'aiModels': ['model-a', 'model-b', 'model-a', '  '],
      'aiIncludeTerminalContext': true,
      'aiReasoningEffort': 'high',
    });
    final restored = AppSettings.fromJson(settings.toJson());

    expect(restored.aiModels, ['model-a', 'model-b']);
    expect(restored.aiModel, 'model-b');
    expect(restored.aiIncludeTerminalContext, isTrue);
    expect(restored.aiReasoningEffort, 'high');
  });

  test('unsupported reasoning effort falls back to provider default', () {
    final settings = AppSettings.fromJson({
      'aiReasoningEffort': 'ultra-unknown',
    });

    expect(settings.aiReasoningEffort, defaultAiReasoningEffort);
  });
}
