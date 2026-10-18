import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One file listed in a ZIP's central directory.
class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.isCompressed,
  });

  final String name;
  final int compressedSize;
  final int uncompressedSize;
  final bool isCompressed;
}

class ZipFormatException implements Exception {
  const ZipFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

const _endOfCentralDirectorySignature = 0x06054b50;
const _centralDirectoryEntrySignature = 0x02014b50;
const _localFileHeaderSignature = 0x04034b50;
const _endRecordSize = 22;
const _centralHeaderSize = 46;
const _localHeaderSize = 30;
const _maxCommentSize = 0xFFFF;

/// Bit 3 of an entry's flags: its CRC and sizes follow the data, in a data
/// descriptor, instead of being in the local header.
const _dataDescriptorFlag = 0x08;
const _copyChunkSize = 1 << 20;

/// Lists an APK's files by reading only its central directory.
///
/// An APK is a ZIP. Reading the directory at the end of the file, instead of
/// unpacking it, takes milliseconds even for a 75 MB APK and needs no
/// external tool. The APK Signing Block sits between the entries and the
/// directory, which is fine: the end record points straight at the
/// directory. ZIP64 isn't supported; an APK never needs it.
Future<List<ZipEntry>> readZipDirectory(String path) async {
  final file = await File(path).open();
  try {
    return [
      for (final record in await _readCentralDirectory(file)) record.entry,
    ];
  } finally {
    await file.close();
  }
}

/// Writes to [output] a copy of the ZIP at [input] with only the entries
/// whose name [keep] accepts, and returns how many it kept.
///
/// Each kept entry is copied as it's stored, never recompressed, so an
/// uncompressed native library stays uncompressed. Left behind: whatever
/// sits between the entries and the directory (an APK Signing Block, so the
/// copy is unsigned), data descriptors (their CRC and sizes go into the
/// local header instead) and the archive comment. The copy isn't aligned:
/// zipalign it before signing.
///
/// When it fails after starting to write, [output] is deleted.
Future<int> copyZipEntries(
  String input,
  String output, {
  required bool Function(String name) keep,
}) async {
  final source = await File(input).open();
  try {
    final records = await _readCentralDirectory(source);
    final sink = await File(output).open(mode: FileMode.write);
    try {
      try {
        return await _writeCopy(source, sink, records, keep);
      } finally {
        await sink.close();
      }
    } catch (_) {
      await File(output).delete();
      rethrow;
    }
  } finally {
    await source.close();
  }
}

Future<int> _writeCopy(
  RandomAccessFile source,
  RandomAccessFile sink,
  List<_Record> records,
  bool Function(String name) keep,
) async {
  final directory = BytesBuilder(copy: false);
  var position = 0;
  var count = 0;

  for (final record in records) {
    if (!keep(record.entry.name)) continue;
    if (record.localHeaderOffset == 0xFFFFFFFF ||
        record.entry.compressedSize == 0xFFFFFFFF) {
      throw const ZipFormatException('ZIP64 archives are not supported.');
    }

    await source.setPosition(record.localHeaderOffset);
    final header = await source.read(_localHeaderSize);
    final local = ByteData.sublistView(header);
    if (header.length < _localHeaderSize ||
        local.getUint32(0, Endian.little) != _localFileHeaderSignature) {
      throw ZipFormatException(
        'Broken ZIP file: no local header for ${record.entry.name}.',
      );
    }
    final nameAndExtra = await source.read(
      local.getUint16(26, Endian.little) + local.getUint16(28, Endian.little),
    );
    // The central directory's CRC and sizes are always right; a local
    // header followed by a data descriptor has zeros there.
    final flags = record.flags & ~_dataDescriptorFlag;
    local
      ..setUint16(6, flags, Endian.little)
      ..setUint32(14, record.crc32, Endian.little)
      ..setUint32(18, record.entry.compressedSize, Endian.little)
      ..setUint32(22, record.entry.uncompressedSize, Endian.little);
    await sink.writeFrom(header);
    await sink.writeFrom(nameAndExtra);

    var remaining = record.entry.compressedSize;
    while (remaining > 0) {
      final chunk = await source.read(
        remaining < _copyChunkSize ? remaining : _copyChunkSize,
      );
      if (chunk.isEmpty) {
        throw ZipFormatException(
          'Broken ZIP file: ${record.entry.name} is cut short.',
        );
      }
      await sink.writeFrom(chunk);
      remaining -= chunk.length;
    }

    final central = Uint8List.fromList(record.bytes);
    ByteData.sublistView(central)
      ..setUint16(8, flags, Endian.little)
      ..setUint32(42, position, Endian.little);
    directory.add(central);

    position +=
        header.length + nameAndExtra.length + record.entry.compressedSize;
    count++;
  }

  final directorySize = directory.length;
  await sink.writeFrom(directory.takeBytes());
  final end = ByteData(_endRecordSize)
    ..setUint32(0, _endOfCentralDirectorySignature, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, directorySize, Endian.little)
    ..setUint32(16, position, Endian.little);
  await sink.writeFrom(end.buffer.asUint8List());
  return count;
}

/// One central directory record: the entry, plus what copying it needs.
class _Record {
  const _Record({
    required this.entry,
    required this.bytes,
    required this.flags,
    required this.crc32,
    required this.localHeaderOffset,
  });

  final ZipEntry entry;

  /// The whole record, as it is in the directory.
  final Uint8List bytes;
  final int flags;
  final int crc32;
  final int localHeaderOffset;
}

Future<List<_Record>> _readCentralDirectory(RandomAccessFile file) async {
  final length = await file.length();
  if (length < _endRecordSize) {
    throw const ZipFormatException('Not a ZIP file: too short.');
  }

  final tailLength = length < _endRecordSize + _maxCommentSize
      ? length
      : _endRecordSize + _maxCommentSize;
  await file.setPosition(length - tailLength);
  final tail = ByteData.sublistView(await file.read(tailLength));

  final endRecord = _findEndRecord(tail);
  if (endRecord == null) {
    throw const ZipFormatException(
      'Not a ZIP file: no end of central directory record.',
    );
  }
  final entryCount = tail.getUint16(endRecord + 10, Endian.little);
  final directorySize = tail.getUint32(endRecord + 12, Endian.little);
  final directoryOffset = tail.getUint32(endRecord + 16, Endian.little);
  if (entryCount == 0xFFFF || directoryOffset == 0xFFFFFFFF) {
    throw const ZipFormatException('ZIP64 archives are not supported.');
  }
  if (directoryOffset + directorySize > length) {
    throw const ZipFormatException(
      'Broken ZIP file: the central directory is past the end.',
    );
  }

  await file.setPosition(directoryOffset);
  final directory = ByteData.sublistView(await file.read(directorySize));
  return _parseDirectory(directory, entryCount);
}

int? _findEndRecord(ByteData tail) {
  for (
    var offset = tail.lengthInBytes - _endRecordSize;
    offset >= 0;
    offset--
  ) {
    if (tail.getUint32(offset, Endian.little) ==
        _endOfCentralDirectorySignature) {
      return offset;
    }
  }
  return null;
}

List<_Record> _parseDirectory(ByteData directory, int entryCount) {
  final records = <_Record>[];
  var offset = 0;
  for (var index = 0; index < entryCount; index++) {
    if (offset + _centralHeaderSize > directory.lengthInBytes ||
        directory.getUint32(offset, Endian.little) !=
            _centralDirectoryEntrySignature) {
      throw const ZipFormatException('Broken ZIP file: bad directory entry.');
    }
    final method = directory.getUint16(offset + 10, Endian.little);
    final compressedSize = directory.getUint32(offset + 20, Endian.little);
    final uncompressedSize = directory.getUint32(offset + 24, Endian.little);
    final nameLength = directory.getUint16(offset + 28, Endian.little);
    final extraLength = directory.getUint16(offset + 30, Endian.little);
    final commentLength = directory.getUint16(offset + 32, Endian.little);
    final recordLength =
        _centralHeaderSize + nameLength + extraLength + commentLength;
    if (offset + recordLength > directory.lengthInBytes) {
      throw const ZipFormatException('Broken ZIP file: bad directory entry.');
    }
    final nameBytes = Uint8List.sublistView(
      directory,
      offset + _centralHeaderSize,
      offset + _centralHeaderSize + nameLength,
    );
    records.add(
      _Record(
        entry: ZipEntry(
          name: utf8.decode(nameBytes, allowMalformed: true),
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          isCompressed: method != 0,
        ),
        bytes: Uint8List.sublistView(directory, offset, offset + recordLength),
        flags: directory.getUint16(offset + 8, Endian.little),
        crc32: directory.getUint32(offset + 16, Endian.little),
        localHeaderOffset: directory.getUint32(offset + 42, Endian.little),
      ),
    );
    offset += recordLength;
  }
  return records;
}
