import 'dart:typed_data';

import 'package:mcumgr_dart/mcumgr_dart.dart';
import 'package:test/test.dart';

void main() {
  group('SmpMessage', () {
    test('encodes and round-trips the 8-byte header + CBOR payload', () {
      final msg = SmpMessage(
        op: SmpOp.writeReq,
        group: 0,
        id: 0,
        seq: 42,
        payload: {'d': 'hi'},
      );
      final bytes = msg.toBytes();

      // Header: op, flags, len(BE), group(BE), seq, id.
      final bd = ByteData.sublistView(bytes);
      expect(bd.getUint8(0), SmpOp.writeReq.value);
      expect(bd.getUint8(6), 42); // seq
      expect(bytes.length, SmpMessage.headerLength + bd.getUint16(2));

      final parsed = SmpMessage.fromBytes(bytes);
      expect(parsed.op, SmpOp.writeReq);
      expect(parsed.group, 0);
      expect(parsed.seq, 42);
      expect(parsed.payload['d'], 'hi');
    });

    test('normalises SMP v1 rc: 0 is success (null), non-zero is the code', () {
      SmpMessage withPayload(Map<String, Object?> p) => SmpMessage.fromBytes(
            SmpMessage(op: SmpOp.writeRsp, group: 0, id: 0, seq: 0, payload: p)
                .toBytes(),
          );

      expect(withPayload({'rc': 0}).rc, isNull);
      expect(withPayload({'rc': 0}).isError, isFalse);
      expect(withPayload({'rc': 3}).rc, 3);
      expect(withPayload({'rc': 3}).isError, isTrue);
      expect(withPayload({}).rc, isNull);
    });

    test('normalises SMP v2 err {group, rc} and labels the group', () {
      final msg = SmpMessage.fromBytes(
        SmpMessage(
          op: SmpOp.writeRsp,
          group: 1,
          id: 0,
          seq: 0,
          payload: {
            'err': {'group': 1, 'rc': 10}
          },
        ).toBytes(),
      );
      expect(msg.rc, 10);
      expect(msg.errGroup, 1);
      expect(msg.errorLabel, contains('flash open failed'));
    });
  });
}
