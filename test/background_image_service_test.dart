import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/storage/background_image_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory temporaryDirectory;
  late Directory supportDirectory;
  late BackgroundImageService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'netcatty-background-test-',
    );
    supportDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}current-container',
    );
    service = BackgroundImageService(
      supportDirectory: () async => supportDirectory,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('repairs a background path after the app container changes', () async {
    final managedDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}custom-backgrounds',
    );
    await managedDirectory.create(recursive: true);
    final currentFile = File(
      '${managedDirectory.path}${Platform.pathSeparator}background-123.jpg',
    );
    await currentFile.writeAsBytes([1, 2, 3]);

    const oldIosPath =
        '/var/mobile/Containers/Data/Application/OLD-UUID/Library/'
        'Application Support/custom-backgrounds/background-123.jpg';

    expect(
        await service.resolveStoredPath(oldIosPath), currentFile.absolute.path);
  });

  test('keeps an existing background path unchanged', () async {
    final file = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}existing.png',
    );
    await file.writeAsBytes([1]);

    expect(await service.resolveStoredPath(file.path), file.absolute.path);
  });

  test('keeps a missing path so the UI can report the read failure', () async {
    const missing = '/old-container/custom-backgrounds/missing.jpg';

    expect(await service.resolveStoredPath(missing), missing);
  });

  test('repairs a legacy Windows path by file name', () async {
    final managedDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}custom-backgrounds',
    );
    await managedDirectory.create(recursive: true);
    final currentFile = File(
      '${managedDirectory.path}${Platform.pathSeparator}background-456.png',
    );
    await currentFile.writeAsBytes([4, 5, 6]);

    const oldWindowsPath =
        r'C:\old-container\custom-backgrounds\background-456.png';

    expect(
      await service.resolveStoredPath(oldWindowsPath),
      currentFile.absolute.path,
    );
  });

  test('stores a managed image as a portable reference', () async {
    final managedDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}custom-backgrounds',
    );
    await managedDirectory.create(recursive: true);
    final currentFile = File(
      '${managedDirectory.path}${Platform.pathSeparator}background-789.jpg',
    );
    await currentFile.writeAsBytes([7, 8, 9]);

    final stored = await service.toStoredPath(currentFile.path);

    expect(stored, 'netcatty-background:background-789.jpg');
    expect(
      await service.resolveStoredPath(stored),
      currentFile.absolute.path,
    );
  });

  test('does not rewrite an image outside the managed directory', () async {
    final external = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}external.jpg',
    );
    await external.writeAsBytes([1]);

    expect(await service.toStoredPath(external.path), external.path);
  });

  test('repository stores portable paths and resolves them when loading',
      () async {
    final managedDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}custom-backgrounds',
    );
    await managedDirectory.create(recursive: true);
    final currentFile = File(
      '${managedDirectory.path}${Platform.pathSeparator}background-999.jpg',
    );
    await currentFile.writeAsBytes([9, 9, 9]);
    final repository = await VaultRepository.open(
      backgroundImageService: service,
    );

    await repository.saveSettings(
      AppSettings(
        customBackgroundEnabled: true,
        customBackgroundPath: currentFile.path,
      ),
    );

    final preferences = await SharedPreferences.getInstance();
    final stored = jsonDecode(
      preferences.getString('netcatty_mobile_settings_v1')!,
    ) as Map<String, dynamic>;
    expect(
      stored['customBackgroundPath'],
      'netcatty-background:background-999.jpg',
    );
    expect(
      (await repository.loadSettings()).customBackgroundPath,
      currentFile.absolute.path,
    );
  });

  test('repository migrates a legacy container path automatically', () async {
    final managedDirectory = Directory(
      '${supportDirectory.path}${Platform.pathSeparator}custom-backgrounds',
    );
    await managedDirectory.create(recursive: true);
    final currentFile = File(
      '${managedDirectory.path}${Platform.pathSeparator}background-legacy.jpg',
    );
    await currentFile.writeAsBytes([1, 3, 5]);
    const oldIosPath =
        '/var/mobile/Containers/Data/Application/OLD-UUID/Library/'
        'Application Support/custom-backgrounds/background-legacy.jpg';
    SharedPreferences.setMockInitialValues({
      'netcatty_mobile_settings_v1': jsonEncode(
        const AppSettings(
          customBackgroundEnabled: true,
          customBackgroundPath: oldIosPath,
        ).toJson(),
      ),
    });
    final repository = await VaultRepository.open(
      backgroundImageService: service,
    );

    final loaded = await repository.loadSettings();

    expect(loaded.customBackgroundPath, currentFile.absolute.path);
    final preferences = await SharedPreferences.getInstance();
    final migrated = jsonDecode(
      preferences.getString('netcatty_mobile_settings_v1')!,
    ) as Map<String, dynamic>;
    expect(
      migrated['customBackgroundPath'],
      'netcatty-background:background-legacy.jpg',
    );
  });
}
