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
const _endRecordSize = 22;
const _maxCommentSize = 0xFFFF;

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
  } finally {
    await file.close();
  }
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

List<ZipEntry> _parseDirectory(ByteData directory, int entryCount) {
  final entries = <ZipEntry>[];
  var offset = 0;
  for (var index = 0; index < entryCount; index++) {
    if (offset + 46 > directory.lengthInBytes ||
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
    final nameBytes = Uint8List.sublistView(
      directory,
      offset + 46,
      offset + 46 + nameLength,
    );
    entries.add(
      ZipEntry(
        name: utf8.decode(nameBytes, allowMalformed: true),
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        isCompressed: method != 0,
      ),
    );
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}
