// Copyright (c) 2024 ProtoCentral
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:mcumgr_dart/mcumgr_dart.dart';
import 'package:test/test.dart';

import 'fake_transport.dart';

/// MCUmgr settings group (3): read/write (0), delete (1), commit (2),
/// load/save (3).
void main() {
  late FakeTransport t;
  late SmpClient client;
  late SettingsMgmt settings;

  setUp(() {
    t = FakeTransport();
    client = SmpClient(t);
    settings = SettingsMgmt(client);
  });

  tearDown(() => client.dispose());

  Future<T> answer<T>(
      Future<T> Function() call, Map<String, Object?> payload) async {
    final f = call();
    await Future<void>.delayed(Duration.zero);
    t.reply(payload);
    return f;
  }

  group('read', () {
    test('sends a read to group 3 / id 0 with the key name', () async {
      final v = await answer(() => settings.read('app/led'), {
        'val': Uint8List.fromList([1, 0, 0, 0])
      });

      final req = t.written.single;
      expect(req.group, 3);
      expect(req.id, 0);
      expect(req.op, SmpOp.readReq);
      expect(req.payload['name'], 'app/led');
      expect(req.payload.containsKey('max_size'), isFalse,
          reason: 'omitted max_size must let the device use its own limit');

      expect(v.bytes, [1, 0, 0, 0]);
      expect(v.truncated, isFalse);
    });

    test('max_size is forwarded when given', () async {
      await answer(() => settings.read('k', maxSize: 16), {'val': <int>[]});
      expect(t.written.single.payload['max_size'], 16);
    });

    test('a bstr decoded as List<int> still becomes bytes', () async {
      // CBOR byte strings come back as List<int> through the decoder.
      final v = await answer(() => settings.read('k'), {
        'val': [0xde, 0xad]
      });
      expect(v.bytes, [0xde, 0xad]);
    });

    test('a missing val is empty, not an error', () async {
      expect((await answer(() => settings.read('k'), {})).bytes, isEmpty);
    });
  });

  group('truncation', () {
    test('read surfaces a short value as truncated', () async {
      // Zephyr signals truncation by adding max_size to an otherwise ordinary
      // SUCCESS response. A client that ignores it reads a short value as a
      // whole one.
      final v = await answer(() => settings.read('long/key'), {
        'val': [1, 2, 3, 4, 5, 6, 7, 8],
        'max_size': 8,
      });
      expect(v.truncated, isTrue);
      expect(v.maxSize, 8);
    });

    test('a truncated integer decodes to null, never to a wrong number', () {
      // A short integer is not a partial value, it is a different value.
      final v =
          SettingValue(bytes: Uint8List.fromList([1, 0, 0, 0]), maxSize: 4);
      expect(v.asInt(), isNull);
      expect(v.asBool(), isNull);
    });

    test('a truncated string still decodes, because it is partial', () {
      final v = SettingValue(
          bytes: Uint8List.fromList(utf8.encode('hel')), maxSize: 3);
      expect(v.asString(), 'hel');
      expect(v.truncated, isTrue,
          reason: 'the caller must still be able to see it was cut');
    });
  });

  group('SettingValue decoding', () {
    SettingValue of(List<int> b) => SettingValue(bytes: Uint8List.fromList(b));

    test('little-endian integers at each supported width', () {
      expect(of([0x2a]).asInt(), 42);
      expect(of([0x00, 0x01]).asInt(), 256);
      expect(of([0x01, 0x00, 0x00, 0x00]).asInt(), 1);
      expect(of([1, 0, 0, 0, 0, 0, 0, 0]).asInt(), 1);
    });

    test('signed decoding is opt-in', () {
      expect(of([0xff]).asInt(), 255);
      expect(of([0xff]).asInt(signed: true), -1);
    });

    test('an unsupported width is null rather than a guess', () {
      expect(of([1, 2, 3]).asInt(), isNull);
      expect(of([]).asInt(), isNull);
    });

    test('bool is a single byte, false only when zero', () {
      expect(of([0]).asBool(), isFalse);
      expect(of([1]).asBool(), isTrue);
      expect(of([2]).asBool(), isTrue);
      expect(of([0, 0]).asBool(), isNull);
    });

    test('strings drop exactly one trailing NUL', () {
      expect(of(utf8.encode('hi')).asString(), 'hi');
      expect(of([...utf8.encode('hi'), 0]).asString(), 'hi');
      // Only one: a second NUL is part of the value.
      expect(of([...utf8.encode('hi'), 0, 0]).asString(), 'hi\u0000');
    });

    test('invalid UTF-8 is null, not replacement characters', () {
      expect(of([0xff, 0xfe]).asString(), isNull);
    });
  });

  group('write', () {
    test('sends raw bytes as val', () async {
      await answer(
          () => settings.write('k', Uint8List.fromList([9, 8])), {'rc': 0});
      final req = t.written.single;
      expect(req.op, SmpOp.writeReq);
      expect(req.group, 3);
      expect(req.id, 0);
      expect(req.payload['name'], 'k');
      expect(req.payload['val'], [9, 8]);
    });

    test('writeInt encodes little-endian at the requested width', () async {
      await answer(() => settings.writeInt('k', 258, width: 2), {'rc': 0});
      expect(t.written.single.payload['val'], [0x02, 0x01]);
    });

    test('writeInt defaults to 4 bytes', () async {
      await answer(() => settings.writeInt('k', 1), {'rc': 0});
      expect((t.written.single.payload['val'] as List).length, 4);
    });

    test('an unsupported width is rejected before it reaches the device', () {
      expect(() => settings.writeInt('k', 1, width: 3), throwsArgumentError);
      expect(t.written, isEmpty);
    });

    test('writeBool sends one byte', () async {
      await answer(() => settings.writeBool('k', true), {'rc': 0});
      expect(t.written.single.payload['val'], [1]);
    });

    test('writeString is UTF-8, unterminated by default', () async {
      await answer(() => settings.writeString('k', 'hi'), {'rc': 0});
      expect(t.written.single.payload['val'], [0x68, 0x69]);
    });

    test('writeString can null-terminate for C-string firmware', () async {
      await answer(() => settings.writeString('k', 'hi', nullTerminated: true),
          {'rc': 0});
      expect(t.written.single.payload['val'], [0x68, 0x69, 0]);
    });
  });

  group('lifecycle', () {
    test('delete targets id 1', () async {
      await answer(() => settings.delete('k'), {'rc': 0});
      expect(t.written.single.id, 1);
      expect(t.written.single.payload['name'], 'k');
    });

    test('commit is a write to id 2 with no payload', () async {
      await answer(settings.commit, {'rc': 0});
      expect(t.written.single.id, 2);
      expect(t.written.single.op, SmpOp.writeReq);
      expect(t.written.single.payload, isEmpty);
    });

    test('load is a READ of id 3', () async {
      await answer(settings.load, {'rc': 0});
      expect(t.written.single.id, 3);
      expect(t.written.single.op, SmpOp.readReq);
    });

    test('save is a WRITE of id 3, whole-tree when unnamed', () async {
      await answer(settings.save, {'rc': 0});
      expect(t.written.single.id, 3);
      expect(t.written.single.op, SmpOp.writeReq);
      expect(t.written.single.payload.containsKey('name'), isFalse,
          reason: 'an absent name means save everything');
    });

    test('save can target one subtree', () async {
      await answer(() => settings.save(name: 'app'), {'rc': 0});
      expect(t.written.single.payload['name'], 'app');
    });

    test('an empty save name is rejected locally', () {
      // Zephyr answers EINVAL for this; failing here says why.
      expect(() => settings.save(name: ''), throwsArgumentError);
      expect(t.written, isEmpty);
    });
  });

  group('errors', () {
    test('a missing key throws with a readable label', () async {
      // SETTINGS_MGMT_ERR_KEY_NOT_FOUND = 3, in group 3's own namespace.
      await expectLater(
        answer(() => settings.read('nope'), {
          'err': {'group': 3, 'rc': 3}
        }),
        throwsA(isA<SmpException>()
            .having((e) => e.toString(), 'message', contains('key not found'))),
      );
    });

    test('a read-protected key is distinguishable from a missing one',
        () async {
      await expectLater(
        answer(() => settings.read('secret'), {
          'err': {'group': 3, 'rc': 4}
        }),
        throwsA(isA<SmpException>().having((e) => e.toString(), 'message',
            contains('does not support being read'))),
      );
    });
  });
}
