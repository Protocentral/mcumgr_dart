// Copyright (c) 2024 ProtoCentral
// SPDX-License-Identifier: MIT

// A minimal Flutter app that demonstrates driving `mcumgr_dart` over BLE:
// scan for SMP-enabled devices, connect, then run an OS-group **echo** and list
// the device's firmware **images** (Image group). The BLE plumbing lives in
// [SmpBleTransport] (this example package); everything else is the pure-Dart
// `mcumgr_dart` package.
//
// Run on a real device:  flutter run   (in example/ble_universal_ble)
import 'package:flutter/material.dart';
import 'package:mcumgr_dart/mcumgr_dart.dart';
import 'package:universal_ble/universal_ble.dart';

import 'smp_ble_transport.dart';

void main() => runApp(const McumgrDemoApp());

class McumgrDemoApp extends StatelessWidget {
  const McumgrDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mcumgr_dart BLE demo',
      theme: ThemeData.dark(),
      home: const ScanPage(),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _devices = <String, BleDevice>{};
  final _log = <String>[];
  bool _scanning = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    UniversalBle.onScanResult = (device) {
      // In a real app you'd filter by advertised SMP service UUID; here we keep
      // every named device and let connect() gate on the SMP service.
      if (device.name != null && device.name!.isNotEmpty) {
        setState(() => _devices[device.deviceId] = device);
      }
    };
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      await UniversalBle.stopScan();
      setState(() => _scanning = false);
      return;
    }
    setState(() {
      _devices.clear();
      _scanning = true;
    });
    await UniversalBle.startScan();
  }

  void _append(String line) => setState(() => _log.insert(0, line));

  /// Connect, run echo + image list, then disconnect — the whole point.
  Future<void> _runDemo(BleDevice device) async {
    if (_busy) return;
    setState(() => _busy = true);
    await UniversalBle.stopScan();
    setState(() => _scanning = false);

    final transport = SmpBleTransport(device.deviceId, name: device.name);
    final client = SmpClient(transport);
    try {
      _append('Connecting to ${device.name}…');
      await transport.connect();
      _append('Connected (maxWrite=${transport.maxWriteLength ?? "?"})');

      final os = OsMgmt(client);
      final reply = await os.echo('hello from mcumgr_dart');
      _append('echo → $reply');

      final img = ImgMgmt(client,
          maxWriteLength: () => transport.maxWriteLength);
      final images = await img.list();
      for (final slot in images) {
        _append('image ${slot.image} slot ${slot.slot} v${slot.version} '
            '${slot.confirmed ? "confirmed" : "pending"} ${slot.shortHash}');
      }
      if (images.isEmpty) _append('(no images reported)');
    } on SmpException catch (e) {
      _append('SMP error: ${e.message}');
    } on SmpTransportException catch (e) {
      _append('Transport error: ${e.message}');
    } catch (e) {
      _append('Error: $e');
    } finally {
      await client.dispose();
      await transport.disconnect();
      await transport.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices.values.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('mcumgr_dart BLE demo'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _toggleScan,
            icon: Icon(_scanning ? Icons.stop : Icons.search),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 220,
            child: ListView.builder(
              itemCount: devices.length,
              itemBuilder: (_, i) {
                final d = devices[i];
                return ListTile(
                  title: Text(d.name ?? d.deviceId),
                  subtitle: Text(d.deviceId),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : () => _runDemo(d),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(
                _log[i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
