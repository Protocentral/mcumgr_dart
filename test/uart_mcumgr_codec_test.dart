// Copyright (c) 2024 ProtoCentral
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:mcumgr_dart/mcumgr_dart.dart';
import 'package:test/test.dart';

Uint8List _frame({int seq = 7, Map<String, Object?> payload = const {}}) =>
    SmpMessage(
      op: SmpOp.writeReq,
      group: 64,
      id: 0x20,
      seq: seq,
      payload: payload,
    ).toBytes();

void main() {
  group('UartMcumgrCodec.crc16Xmodem', () {
    test('matches the reference vector for "123456789"', () {
      expect(UartMcumgrCodec.crc16Xmodem(ascii.encode('123456789')), 0x31C3);
    });

    test('is 0 over no bytes', () {
      expect(UartMcumgrCodec.crc16Xmodem(const <int>[]), 0x0000);
    });
  });

  group('UartMcumgrCodec.encode', () {
    test('wraps one frame in a single start-marker line by default', () {
      final frame = _frame();
      final lines = UartMcumgrCodec.encode(frame);

      expect(lines, hasLength(1));
      final line = lines.single;
      expect(line[0], UartMcumgrCodec.startMarker0);
      expect(line[1], UartMcumgrCodec.startMarker1);
      expect(line.last, 0x0a);

      final pkt = base64.decode(
        String.fromCharCodes(line.sublist(2, line.length - 1)),
      );
      // Length prefix counts the body plus the 2 CRC bytes.
      expect((pkt[0] << 8) | pkt[1], frame.length + 2);
      expect(pkt.sublist(2, 2 + frame.length), frame);
      // CRC covers the body only.
      final crc = (pkt[pkt.length - 2] << 8) | pkt[pkt.length - 1];
      expect(crc, UartMcumgrCodec.crc16Xmodem(frame));
    });

    test('splits long packets across continuation lines', () {
      final frame = _frame(payload: {'d': 'x' * 400});
      final lines = UartMcumgrCodec.encode(frame, maxLineLength: 64);

      expect(lines.length, greaterThan(1));
      expect(lines.first[0], UartMcumgrCodec.startMarker0);
      for (final line in lines.skip(1)) {
        expect(line[0], UartMcumgrCodec.continuationMarker0);
        expect(line[1], UartMcumgrCodec.continuationMarker1);
      }
      for (final line in lines) {
        expect(line.length, lessThanOrEqualTo(64));
      }
    });

    test('rejects a line budget too small to carry a base64 quantum', () {
      expect(
        () => UartMcumgrCodec.encode(_frame(), maxLineLength: 10),
        throwsArgumentError,
      );
    });
  });

  group('UartMcumgrDecoder', () {
    test('round-trips a single-line packet back to the original frame', () {
      final frame = _frame(payload: {'rc': 0});
      final decoder = UartMcumgrDecoder();

      final out = decoder.add(UartMcumgrCodec.encode(frame).single);

      expect(out, hasLength(1));
      expect(out.single, frame);
      expect(decoder.badFrames, 0);
    });

    test('reassembles a packet split across continuation lines', () {
      final frame = _frame(payload: {'d': 'y' * 300});
      final decoder = UartMcumgrDecoder();
      final lines = UartMcumgrCodec.encode(frame, maxLineLength: 48);
      expect(lines.length, greaterThan(2));

      final out = <Uint8List>[];
      for (final line in lines) {
        out.addAll(decoder.add(line));
      }

      expect(out, hasLength(1));
      expect(out.single, frame);
    });

    test('tolerates arbitrary chunk boundaries, including byte at a time', () {
      final frame = _frame(payload: {'off': 1234});
      final decoder = UartMcumgrDecoder();
      final line = UartMcumgrCodec.encode(frame).single;

      final out = <Uint8List>[];
      for (final b in line) {
        out.addAll(decoder.add(<int>[b]));
      }

      expect(out, hasLength(1));
      expect(out.single, frame);
    });

    test('returns several frames delivered in one chunk', () {
      final decoder = UartMcumgrDecoder();
      final a = _frame(seq: 1);
      final b = _frame(seq: 2);

      final out = decoder.add(<int>[
        ...UartMcumgrCodec.encode(a).single,
        ...UartMcumgrCodec.encode(b).single,
      ]);

      expect(out.map((f) => SmpMessage.fromBytes(f).seq), <int>[1, 2]);
    });

    test('ignores console text sharing the pipe, and CRLF line endings', () {
      final frame = _frame();
      final decoder = UartMcumgrDecoder();

      expect(decoder.add(ascii.encode('*** Booting Zephyr ***\r\n')), isEmpty);
      final out = decoder.add(<int>[
        ...UartMcumgrCodec.encode(frame).single.sublist(0,
            UartMcumgrCodec.encode(frame).single.length - 1),
        0x0d,
        0x0a,
      ]);

      expect(out, hasLength(1));
      expect(out.single, frame);
      expect(decoder.badFrames, 0);
    });

    test('drops a corrupted packet, counts it, and recovers on the next', () {
      final decoder = UartMcumgrDecoder();
      final bad = UartMcumgrCodec.encode(_frame(seq: 1)).single;
      // Flip a base64 character inside the body, breaking the CRC.
      bad[6] = bad[6] == 0x41 ? 0x42 : 0x41;

      expect(decoder.add(bad), isEmpty);
      expect(decoder.badFrames, 1);

      final good = _frame(seq: 2);
      final out = decoder.add(UartMcumgrCodec.encode(good).single);
      expect(out, hasLength(1));
      expect(SmpMessage.fromBytes(out.single).seq, 2);
    });

    test('ignores a continuation line with no start marker', () {
      final decoder = UartMcumgrDecoder();
      final line = UartMcumgrCodec.encode(_frame()).single;
      line[0] = UartMcumgrCodec.continuationMarker0;
      line[1] = UartMcumgrCodec.continuationMarker1;

      expect(decoder.add(line), isEmpty);
      expect(decoder.badFrames, 0);
    });

    test('reset discards a half-received packet', () {
      final decoder = UartMcumgrDecoder();
      final lines = UartMcumgrCodec.encode(
        _frame(payload: {'d': 'z' * 300}),
        maxLineLength: 48,
      );

      expect(decoder.add(lines.first), isEmpty);
      decoder.reset();
      // The remaining continuations now have no start marker to attach to.
      final out = <Uint8List>[];
      for (final line in lines.skip(1)) {
        out.addAll(decoder.add(line));
      }
      expect(out, isEmpty);
    });
  });
}
