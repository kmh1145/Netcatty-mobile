import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_export_service.dart';

void main() {
  test('mobile export passes the complete JSON payload to the document picker',
      () async {
    Uint8List? savedBytes;
    FileType? savedType;
    List<String>? savedExtensions;
    final service = VaultExportService(
      pickerWritesBytes: true,
      saveFile: ({
        dialogTitle,
        fileName,
        type = FileType.any,
        allowedExtensions,
        bytes,
      }) async {
        savedBytes = bytes;
        savedType = type;
        savedExtensions = allowedExtensions;
        return '/document/netcatty-mobile-export.json';
      },
    );
    final vault = VaultData.fromJson({
      'hosts': [
        {
          'id': 'host-1',
          'label': 'NAS',
          'hostname': '192.0.2.10',
          'username': 'root',
          'password': 'secret',
        },
      ],
      'keys': [],
      'snippets': [],
      'customGroups': ['Home'],
      'desktopPluginData': {'preserved': true},
    });

    final result = await service.export(vault);

    expect(result, VaultExportResult.saved);
    expect(savedType, FileType.custom);
    expect(savedExtensions, ['json']);
    expect(savedBytes, isNotNull);
    final json = jsonDecode(utf8.decode(savedBytes!)) as Map<String, dynamic>;
    expect((json['hosts'] as List).single['password'], 'secret');
    expect(json['desktopPluginData'], {'preserved': true});
  });

  test('desktop export writes JSON to the selected filesystem path', () async {
    final directory = await Directory.systemTemp.createTemp('vault-export-');
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/vault.json');
    Uint8List? pickerBytes;
    final service = VaultExportService(
      pickerWritesBytes: false,
      saveFile: ({
        dialogTitle,
        fileName,
        type = FileType.any,
        allowedExtensions,
        bytes,
      }) async {
        pickerBytes = bytes;
        return destination.path;
      },
    );

    final result = await service.export(VaultData.empty());

    expect(result, VaultExportResult.saved);
    expect(pickerBytes, isNull);
    expect(destination.existsSync(), isTrue);
    expect(
      jsonDecode(await destination.readAsString()),
      containsPair('hosts', isEmpty),
    );
  });

  test('cancelled export does not report success', () async {
    final service = VaultExportService(
      pickerWritesBytes: true,
      saveFile: ({
        dialogTitle,
        fileName,
        type = FileType.any,
        allowedExtensions,
        bytes,
      }) async =>
          null,
    );

    expect(
      await service.export(VaultData.empty()),
      VaultExportResult.cancelled,
    );
  });
}
