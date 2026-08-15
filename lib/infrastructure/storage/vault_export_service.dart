import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../domain/models/vault.dart';

enum VaultExportResult { saved, cancelled }

typedef SaveVaultFile = Future<String?> Function({
  String? dialogTitle,
  String? fileName,
  FileType type,
  List<String>? allowedExtensions,
  Uint8List? bytes,
});

class VaultExportService {
  VaultExportService({
    SaveVaultFile? saveFile,
    bool? pickerWritesBytes,
  })  : _saveFile = saveFile ?? FilePicker.platform.saveFile,
        _pickerWritesBytes =
            pickerWritesBytes ?? (Platform.isAndroid || Platform.isIOS);

  final SaveVaultFile _saveFile;
  final bool _pickerWritesBytes;

  Future<VaultExportResult> export(VaultData vault) async {
    final bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(vault.toJson())),
    );
    final path = await _saveFile(
      dialogTitle: '导出 Netcatty 保险库',
      fileName: 'netcatty-mobile-export.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      // Android and iOS document pickers own the selected URI. file_picker
      // must receive the payload so its native implementation can write it.
      bytes: _pickerWritesBytes ? bytes : null,
    );
    if (path == null) return VaultExportResult.cancelled;

    // Desktop implementations return a normal filesystem destination and do
    // not write the provided bytes on the application's behalf.
    if (!_pickerWritesBytes) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return VaultExportResult.saved;
  }
}
