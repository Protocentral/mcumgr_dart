import 'package:mcumgr_dart/mcumgr_dart.dart';
import 'package:test/test.dart';

import 'fake_transport.dart';

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
