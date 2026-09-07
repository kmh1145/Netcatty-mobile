import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'sftp_service.dart';

/// Streams standard ZIP/Deflate with data descriptors. ZIP64 is rejected.
Future<void> zipSelection(FileTransferService source, List<RemoteEntry> entries,
    String destination) async {
  if (!destination.toLowerCase().endsWith('.zip')) {
    throw ArgumentError('Use .zip');
  }
  if ((await source.list(source.parentPath(destination)))
      .any((e) => e.path == destination)) {
    throw StateError('目标文件已存在');
  }
  final members = <({RemoteEntry entry, String name})>[];
  Future<void> scan(RemoteEntry entry, String name) async {
    if (entry.path == destination || destination.startsWith('${entry.path}/')) {
      throw StateError('不能把文件或目录复制到自身');
    }
    if (entry.size >= 0xffffffff || members.length >= 65534) {
      throw StateError('ZIP 暂不支持超过 4GB 的文件或过多条目');
    }
    members.add((entry: entry, name: entry.isDirectory ? '$name/' : name));
    if (entry.isDirectory) {
      for (final child in await source.list(entry.path)) {
        await scan(child, '$name/${child.name}');
      }
    }
  }

  for (final entry in entries) {
    await scan(entry, entry.name);
  }
  final temporary =
      '$destination.${DateTime.now().microsecondsSinceEpoch}.netcatty-part';
  try {
    await source.writeStream(temporary, _zip(source, members));
    await source.rename(temporary, destination);
  } catch (_) {
    try {
      await source.delete(RemoteEntry(
          name: temporary, path: temporary, isDirectory: false, size: 0));
    } catch (_) {}
    rethrow;
  }
}

Uint8List _record(int length, Map<int, int> shorts, Map<int, int> longs) {
  final value = ByteData(length);
  shorts.forEach((offset, n) => value.setUint16(offset, n, Endian.little));
  longs.forEach((offset, n) => value.setUint32(offset, n, Endian.little));
  return value.buffer.asUint8List();
}

final _crcTable = List.generate(256, (n) {
  var c = n;
  for (var bit = 0; bit < 8; bit++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

Stream<Uint8List> _zip(FileTransferService source,
    List<({RemoteEntry entry, String name})> members) async* {
  final central = <Uint8List>[];
  var offset = 0;
  for (final member in members) {
    final name = Uint8List.fromList(utf8.encode(member.name));
    if (name.length > 65535) throw StateError('ZIP 路径过长');
    final start = offset;
    final method = member.entry.isDirectory ? 0 : 8;
    yield _record(30, {4: 20, 6: 0x808, 8: method, 12: 33, 26: name.length},
        {0: 0x04034b50});
    yield name;
    offset += 30 + name.length;
    var size = 0, packed = 0, crc = 0xffffffff;
    Stream<List<int>> read() async* {
      await for (final chunk in source.readStream(member.entry.path)) {
        size += chunk.length;
        if (size >= 0xffffffff) throw StateError('ZIP 暂不支持超过 4GB 的文件或过多条目');
        for (final byte in chunk) {
          crc = _crcTable[(crc ^ byte) & 255] ^ (crc >> 8);
        }
        yield chunk;
      }
    }

    if (!member.entry.isDirectory) {
      await for (final chunk in ZLibCodec(raw: true).encoder.bind(read())) {
        packed += chunk.length;
        offset += chunk.length;
        if (offset >= 0xffffffff) throw StateError('ZIP 暂不支持超过 4GB 的文件或过多条目');
        yield Uint8List.fromList(chunk);
      }
    }
    crc = (crc ^ 0xffffffff) & 0xffffffff;
    yield _record(16, {}, {0: 0x08074b50, 4: crc, 8: packed, 12: size});
    offset += 16;
    central.add(_record(46, {
      4: 20,
      6: 20,
      8: 0x808,
      10: method,
      14: 33,
      28: name.length
    }, {
      0: 0x02014b50,
      16: crc,
      20: packed,
      24: size,
      38: member.entry.isDirectory ? 16 : 0,
      42: start
    }));
    central.add(name);
  }
  final centralStart = offset;
  for (final record in central) {
    yield record;
    offset += record.length;
  }
  if (offset >= 0xffffffff) throw StateError('ZIP 暂不支持超过 4GB 的文件或过多条目');
  yield _record(22, {8: members.length, 10: members.length},
      {0: 0x06054b50, 12: offset - centralStart, 16: centralStart});
}
