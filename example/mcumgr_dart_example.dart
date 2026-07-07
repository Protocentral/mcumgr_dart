// Copyright (c) 2024 ProtoCentral
// SPDX-License-Identifier: MIT

// A runnable, self-contained example: a loopback [SmpTransport] that plays the
// role of a device answering the OS-group **echo** command, driven through the
// real [SmpClient] + [OsMgmt] facade.
//
// Run with:  dart run example/mcumgr_dart_example.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:mcumgr_dart/mcumgr_dart.dart';

/// A fake transport that answers OS echo requests in-process (no hardware).
class LoopbackTransport implements SmpTransport {
  final _rx = StreamController<Uint8List>.broadcast();
  final _states = StreamController<SmpConnectionState>.broadcast();
  SmpConnectionState _state = SmpConnectionState.disconnected;

  @override
  String? get deviceLabel => 'loopback';

  @override
  SmpConnectionState get state => _state;

  @override
  Stream<SmpConnectionState> get stateChanges => _states.stream;

  @override
  Stream<Uint8List> get notifications => _rx.stream;

  @override
  int? get maxWriteLength => 244;

  @override
  Future<void> connect() async {
    _state = SmpConnectionState.connected;
    _states.add(_state);
  }

  @override
  Future<void> write(Uint8List frame) async {
    // Decode the request and synthesise a device response.
    final req = SmpMessage.fromBytes(frame);
    if (req.group == OsMgmt.group && req.id == OsMgmt.idEcho) {
      final rsp = SmpMessage(
        op: SmpOp.writeRsp,
        group: req.group,
        id: req.id,
        seq: req.seq,
        payload: {'r': req.payload['d']},
      );
      // Deliver on the notification stream (optionally fragmented).
      _rx.add(rsp.toBytes());
    }
  }

  @override
  Future<void> disconnect() async {
    _state = SmpConnectionState.disconnected;
    _states.add(_state);
    await _rx.close();
    await _states.close();
  }
}

Future<void> main() async {
  final transport = LoopbackTransport();
  final client = SmpClient(transport);
  await transport.connect();

  final os = OsMgmt(client);
  final reply = await os.echo('hello mcumgr_dart');
  print('echo -> $reply');

  await client.dispose();
  await transport.disconnect();
}
