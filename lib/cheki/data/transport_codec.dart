import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A deliberately small ZIP profile: UTF-8 names, stored or raw-deflate files,
/// no encryption, links, ZIP64, duplicate names, directories or descriptors.
/// Both compressed and expanded sizes are bounded before files are used.
abstract final class TransportZip {
  static const limit = 128 * 1024 * 1024;
  static int crc(List<int> bytes) {
    var n = 0xffffffff;
    for (final b in bytes) {
      n ^= b;
      for (var i = 0; i < 8; i++) {
        n = (n >>> 1) ^ ((n & 1) == 1 ? 0xedb88320 : 0);
      }
    }
    return (n ^ 0xffffffff) & 0xffffffff;
  }

  static void _name(String name) {
    if (name.isEmpty ||
        name.contains('\\') ||
        name.contains(':') ||
        name.contains('\u0000') ||
        name.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw const FormatException('数据包文件路径无效');
    }
  }

  static Uint8List encode(Map<String, List<int>> files) {
    final out = BytesBuilder(), central = BytesBuilder();
    var count = 0, expanded = 0;
    for (final entry in files.entries) {
      _name(entry.key);
      final name = utf8.encode(entry.key), data = entry.value, sum = crc(data);
      expanded += data.length;
      if (expanded > limit || name.length > 65535 || ++count > 2048) {
        throw const FormatException('数据包超过大小或文件数量限制');
      }
      final start = out.length, header = ByteData(30);
      header.setUint32(0, 0x04034b50, Endian.little);
      header.setUint16(4, 20, Endian.little);
      header.setUint16(6, 0x800, Endian.little);
      header.setUint32(14, sum, Endian.little);
      header.setUint32(18, data.length, Endian.little);
      header.setUint32(22, data.length, Endian.little);
      header.setUint16(26, name.length, Endian.little);
      out
        ..add(header.buffer.asUint8List())
        ..add(name)
        ..add(data);
      final h = ByteData(46);
      h.setUint32(0, 0x02014b50, Endian.little);
      h.setUint16(4, 20, Endian.little);
      h.setUint16(6, 20, Endian.little);
      h.setUint16(8, 0x800, Endian.little);
      h.setUint32(16, sum, Endian.little);
      h.setUint32(20, data.length, Endian.little);
      h.setUint32(24, data.length, Endian.little);
      h.setUint16(28, name.length, Endian.little);
      h.setUint32(42, start, Endian.little);
      central
        ..add(h.buffer.asUint8List())
        ..add(name);
    }
    final end = ByteData(22), offset = out.length;
    end.setUint32(0, 0x06054b50, Endian.little);
    end.setUint16(8, count, Endian.little);
    end.setUint16(10, count, Endian.little);
    end.setUint32(12, central.length, Endian.little);
    end.setUint32(16, offset, Endian.little);
    out
      ..add(central.takeBytes())
      ..add(end.buffer.asUint8List());
    if (out.length > limit) throw const FormatException('数据包过大');
    return out.takeBytes();
  }

  static Map<String, Uint8List> decode(Uint8List bytes) {
    Never invalid() => throw const FormatException('ZIP数据包损坏或使用不支持的压缩格式');
    if (bytes.length < 22 || bytes.length > limit) invalid();
    final b = ByteData.sublistView(bytes), end = bytes.length - 22;
    int u16(int p) => b.getUint16(p, Endian.little);
    int u32(int p) => b.getUint32(p, Endian.little);
    if (u32(end) != 0x06054b50 ||
        u16(end + 4) != 0 ||
        u16(end + 6) != 0 ||
        u16(end + 20) != 0 ||
        u16(end + 8) != u16(end + 10)) {
      invalid();
    }
    final count = u16(end + 10), central = u32(end + 16);
    if (count > 2048 || central + u32(end + 12) != end) invalid();
    var pos = central, localEnd = 0, expanded = 0;
    final files = <String, Uint8List>{};
    for (var i = 0; i < count; i++) {
      if (pos + 46 > end || u32(pos) != 0x02014b50) invalid();
      final flags = u16(pos + 8),
          method = u16(pos + 10),
          sum = u32(pos + 16),
          compressed = u32(pos + 20),
          size = u32(pos + 24),
          n = u16(pos + 28),
          extra = u16(pos + 30),
          comment = u16(pos + 32),
          off = u32(pos + 42);
      if ((flags & ~0x800) != 0 ||
          ![0, 8].contains(method) ||
          u16(pos + 34) != 0 ||
          (u32(pos + 38) >>> 16 & 0xf000) == 0xa000 ||
          pos + 46 + n + extra + comment > end ||
          off != localEnd ||
          off + 30 > central) {
        invalid();
      }
      final name = utf8.decode(bytes.sublist(pos + 46, pos + 46 + n));
      _name(name);
      if (files.keys.any((s) => s.toLowerCase() == name.toLowerCase())) {
        invalid();
      }
      if (u32(off) != 0x04034b50 ||
          u16(off + 6) != flags ||
          u16(off + 8) != method ||
          u32(off + 14) != sum ||
          u32(off + 18) != compressed ||
          u32(off + 22) != size ||
          u16(off + 26) != n ||
          off + 30 + n + u16(off + 28) + compressed > central ||
          utf8.decode(bytes.sublist(off + 30, off + 30 + n)) != name) {
        invalid();
      }
      expanded += size;
      if (expanded > limit) invalid();
      final start = off + 30 + n + u16(off + 28),
          raw = bytes.sublist(start, start + compressed);
      Uint8List content;
      if (method == 0) {
        content = Uint8List.fromList(raw);
      } else {
        final chunks = BytesBuilder();
        final sink = ZLibDecoder(
          raw: true,
        ).startChunkedConversion(_BoundedSink(chunks, size));
        for (var p = 0; p < raw.length; p += 4096) {
          sink.add(
            raw.sublist(p, p + 4096 > raw.length ? raw.length : p + 4096),
          );
        }
        sink.close();
        content = chunks.takeBytes();
      }
      if (content.length != size || crc(content) != sum) invalid();
      files[name] = content;
      localEnd = start + compressed;
      pos += 46 + n + extra + comment;
    }
    if (pos != end || localEnd != central) invalid();
    return files;
  }
}

class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.out, this.limit);
  final BytesBuilder out;
  final int limit;
  @override
  void add(List<int> data) {
    if (out.length + data.length > limit) {
      throw const FormatException('解压大小与声明不符');
    }
    out.add(data);
  }

  @override
  void close() {}
}

abstract final class TransportCsv {
  static String encode(List<List<String>> rows) =>
      '${rows.map((r) => r.map((s) => '"${s.replaceAll('"', '""')}"').join(',')).join('\r\n')}\r\n';
  static List<List<String>> decode(String text) {
    if (text.startsWith('\ufeff')) text = text.substring(1);
    final rows = <List<String>>[], row = <String>[];
    var field = StringBuffer(), quoted = false, closed = false, started = false;
    void cell() {
      row.add(field.toString());
      field = StringBuffer();
      closed = false;
      started = false;
    }

    void end() {
      cell();
      rows.add(List.of(row));
      row.clear();
    }

    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
            closed = true;
          }
        } else {
          field.write(c);
        }
      } else if (c == ',' || c == '\r' || c == '\n') {
        if (c == ',') {
          cell();
        } else {
          end();
          if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        }
      } else if (c == '"' && !started && !closed) {
        quoted = true;
        started = true;
      } else {
        if (closed || c == '"') throw const FormatException('CSV引号或分隔符无效');
        started = true;
        field.write(c);
      }
    }
    if (quoted) throw const FormatException('CSV引号未闭合');
    if (started || closed || row.isNotEmpty) end();
    return rows;
  }
}
