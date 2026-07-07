import 'dart:async';
import 'dart:typed_data';

import 'package:mcumgr_dart/mcumgr_dart.dart';
import 'package:test/test.dart';

/// Test transport: captures written frames and lets the test push raw inbound
/// bytes (optionally split into fragments) back onto the notification stream.
class FakeTransport implements SmpTransport {
  final _rx = StreamController<Uint8List>.broadcast();
  final List<SmpMessage> written = [];

  @override
  String? get deviceLabel => 'fake';
  @override
  SmpConnectionState get state => SmpConnectionState.connected;
  @override
  Stream<SmpConnectionState> get stateChanges => const Stream.empty();
  @override
  Stream<Uint8List> get notifications => _rx.stream;
  @override
  int? get maxWriteLength => 244;
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async => _rx.close();

  @override
  Future<void> write(Uint8List frame) async {
    written.add(SmpMessage.fromBytes(frame));
  }

  /// Reply to the most recent request, echoing its seq, with [payload].
  /// [fragments] splits the response bytes to exercise reassembly.
  void reply(Map<String, Object?> payload, {int fragments = 1}) {
    final req = written.last;
    final bytes = SmpMessage(
      op: SmpOp.writeRsp,
      group: req.group,
      id: req.id,
      seq: req.seq,
      payload: payload,
    ).toBytes();

    if (fragments <= 1) {
      _rx.add(bytes);
      return;
    }
    final step = (bytes.length / fragments).ceil();
    for (var i = 0; i < bytes.length; i += step) {
      final end = (i + step < bytes.length) ? i + step : bytes.length;
      _rx.add(Uint8List.sublistView(bytes, i, end));
    }
  }
}

void main() {
  test('matches a response to its request by seq', () async {
    final t = FakeTransport();
    final client = SmpClient(t);
    final future = client.send(op: SmpOp.writeReq, group: 0, id: 0);
    await Future<void>.delayed(Duration.zero);
    t.reply({'r': 'ok'});
    final rsp = await future;
    expect(rsp.payload['r'], 'ok');
    await client.dispose();
  });

  test('reassembles a fragmented notification into one frame', () async {
    final t = FakeTransport();
    final client = SmpClient(t);
    final future = client.send(op: SmpOp.writeReq, group: 8, id: 0);
    await Future<void>.delayed(Duration.zero);
    // Response with a longer payload, delivered in 4 fragments.
    t.reply({'data': List<int>.filled(200, 7), 'off': 0, 'len': 200},
        fragments: 4);
    final rsp = await future;
    expect((rsp.payload['data'] as List).length, 200);
    expect(rsp.payload['len'], 200);
    await client.dispose();
  });

  test('times out an unanswered request', () async {
    final t = FakeTransport();
    final client = SmpClient(t)..timeout = const Duration(milliseconds: 50);
    expect(
      client.send(op: SmpOp.writeReq, group: 0, id: 0),
      throwsA(isA<SmpException>()),
    );
    await client.dispose();
  });
}
