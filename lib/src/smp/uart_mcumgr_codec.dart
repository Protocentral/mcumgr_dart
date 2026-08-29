// Copyright (c) 2024 ProtoCentral
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

/// Encapsulation used by Zephyr's `uart_mcumgr` transport (serial, and any
/// byte stream that tunnels it — a TCP passthrough, a USB CDC pipe).
///
/// Below [SmpTransport] the bytes on a BLE characteristic are the SMP frame
/// itself. A byte stream has no packet boundaries, so Zephyr wraps each frame:
///
/// ```
///   pkt  = len_be16(body.length + 2) || body || crc16_xmodem_be16(body)
///   line = 0x06 0x09 (start) | 0x04 0x14 (continuation) + base64(pkt-chunk) + '\n'
/// ```
///
/// where `body` is the SMP frame — the 8-byte header plus its CBOR payload.
/// The length prefix counts the CRC, and the CRC covers the body only.
///
/// This class is the seam's other half: [encode] turns one SMP frame into the
/// line(s) to write, and [UartMcumgrDecoder] turns an arbitrary byte stream
/// back into whole SMP frames. Both are pure — no `dart:io`, no Flutter — so a
/// transport over serial, TCP or anything else can share them.
abstract final class UartMcumgrCodec {
  /// First line of a packet.
  static const int startMarker0 = 0x06;
  static const int startMarker1 = 0x09;

  /// Continuation of a packet begun by a start marker.
  static const int continuationMarker0 = 0x04;
  static const int continuationMarker1 = 0x14;

  static const int _lf = 0x0a;
  static const int _cr = 0x0d;

  /// Encode one SMP [frame] (8-byte header + CBOR payload) into the lines to
  /// write to the stream, each already terminated with `\n`.
  ///
  /// With [maxLineLength] null — the default — the packet is emitted as a
  /// single start-marker line, which is what every frame small enough to fit
  /// the device's MTU wants. Pass a positive value to split longer packets
  /// across continuation lines; it bounds the whole line, markers and newline
  /// included, and must leave room for at least one base64 quantum (8 bytes).
  static List<Uint8List> encode(Uint8List frame, {int? maxLineLength}) {
    final int crc = crc16Xmodem(frame);
    final Uint8List pkt = Uint8List(frame.length + 4);
    final ByteData bd = ByteData.sublistView(pkt);
    bd.setUint16(0, frame.length + 2);
    pkt.setRange(2, 2 + frame.length, frame);
    bd.setUint16(2 + frame.length, crc);

    final String b64 = base64.encode(pkt);

    if (maxLineLength == null) {
      return <Uint8List>[_line(startMarker0, startMarker1, b64)];
    }
    // 2 marker bytes + 1 newline; base64 must be split on 4-char boundaries so
    // each line decodes independently of the next.
    final int budget = ((maxLineLength - 3) ~/ 4) * 4;
    if (budget < 8) {
      throw ArgumentError.value(
        maxLineLength,
        'maxLineLength',
        'too small to carry a base64 quantum (needs at least 11)',
      );
    }

    final List<Uint8List> lines = <Uint8List>[];
    for (int i = 0; i < b64.length; i += budget) {
      final String chunk =
          b64.substring(i, i + budget < b64.length ? i + budget : b64.length);
      lines.add(i == 0
          ? _line(startMarker0, startMarker1, chunk)
          : _line(continuationMarker0, continuationMarker1, chunk));
    }
    return lines;
  }

  static Uint8List _line(int m0, int m1, String b64) {
    final Uint8List out = Uint8List(2 + b64.length + 1);
    out[0] = m0;
    out[1] = m1;
    for (int i = 0; i < b64.length; i++) {
      out[2 + i] = b64.codeUnitAt(i);
    }
    out[out.length - 1] = _lf;
    return out;
  }

  /// CRC-16/XMODEM — polynomial 0x1021, initial value 0x0000, no reflection.
  static int crc16Xmodem(List<int> data) {
    int crc = 0x0000;
    for (final int b in data) {
      crc ^= (b << 8) & 0xFFFF;
      for (int k = 0; k < 8; k++) {
        crc = (crc & 0x8000) != 0
            ? ((crc << 1) ^ 0x1021) & 0xFFFF
            : (crc << 1) & 0xFFFF;
      }
    }
    return crc & 0xFFFF;
  }
}

/// Incremental decoder for the [UartMcumgrCodec] encapsulation.
///
/// Feed it whatever the stream hands you — partial lines, several lines at
/// once, interleaved console text — and it returns the complete SMP frames it
/// could recover, CRC verified and the length prefix and CRC stripped, ready
/// for `SmpClient`.
///
/// It is deliberately forgiving, because a device's console log usually shares
/// the pipe: a line without a marker is discarded, and a packet whose CRC or
/// declared length does not check out is dropped rather than thrown, so one bad
/// packet cannot wedge the stream. Both cases bump a counter ([badFrames]) so a
/// caller that cares can surface it.
///
/// Accumulation is bounded by [maxPacketBytes]. A device that emits a start
/// marker and then never completes the packet — wedged mid-transmission, or a
/// console line that happens to open with the marker bytes — would otherwise
/// grow the buffer without limit.
class UartMcumgrDecoder {
  UartMcumgrDecoder({this.maxPacketBytes = 4096})
      : assert(maxPacketBytes > 0, 'maxPacketBytes must be positive');

  /// Largest packet to accumulate, in decoded bytes. Once a partial packet
  /// would exceed this it is discarded and counted in [badFrames], and the
  /// decoder waits for the next start marker. The default is comfortably above
  /// any Zephyr `CONFIG_MCUMGR_TRANSPORT_UART_MTU` in practical use.
  final int maxPacketBytes;

  final List<int> _line = <int>[];
  final StringBuffer _b64 = StringBuffer();
  bool _inPacket = false;

  /// Packets discarded for a bad length prefix or a CRC mismatch.
  int get badFrames => _badFrames;
  int _badFrames = 0;

  /// Feed [chunk]; returns any SMP frames completed by it, in order.
  List<Uint8List> add(List<int> chunk) {
    final List<Uint8List> out = <Uint8List>[];
    for (final int b in chunk) {
      if (b == UartMcumgrCodec._lf) {
        final Uint8List? frame = _endLine();
        if (frame != null) out.add(frame);
        _line.clear();
      } else if (b != UartMcumgrCodec._cr) {
        _line.add(b);
      }
    }
    return out;
  }

  /// Drop any partially accumulated packet — call on reconnect, so a truncated
  /// packet from the previous session cannot merge into the next one.
  void reset() {
    _line.clear();
    _b64.clear();
    _inPacket = false;
  }

  Uint8List? _endLine() {
    if (_line.length < 2) return null;
    final int m0 = _line[0];
    final int m1 = _line[1];

    if (m0 == UartMcumgrCodec.startMarker0 &&
        m1 == UartMcumgrCodec.startMarker1) {
      _b64.clear();
      _inPacket = true;
    } else if (m0 == UartMcumgrCodec.continuationMarker0 &&
        m1 == UartMcumgrCodec.continuationMarker1) {
      if (!_inPacket) return null; // continuation with no start — ignore
    } else {
      return null; // console text, not an SMP line
    }

    _b64.write(String.fromCharCodes(_line.sublist(2)));

    // 4 base64 characters carry 3 bytes.
    if ((_b64.length ~/ 4) * 3 > maxPacketBytes) {
      _badFrames++;
      _b64.clear();
      _inPacket = false;
      return null;
    }

    final Uint8List decoded;
    try {
      decoded = base64.decode(_b64.toString());
    } on FormatException {
      return null; // mid-quantum; wait for the next continuation line
    }
    if (decoded.length < 2) return null;

    final int declared = (decoded[0] << 8) | decoded[1];
    if (decoded.length < declared + 2) return null; // more lines to come

    _inPacket = false;
    _b64.clear();

    // declared counts the body plus the 2 CRC bytes.
    if (declared < 2) {
      _badFrames++;
      return null;
    }
    final Uint8List body = Uint8List.sublistView(decoded, 2, declared);
    final int expected = (decoded[declared] << 8) | decoded[declared + 1];
    if (UartMcumgrCodec.crc16Xmodem(body) != expected) {
      _badFrames++;
      return null;
    }
    return body;
  }
}
