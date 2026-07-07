# mcumgr_dart examples

## 1. Pure-Dart loopback (no hardware) — [`mcumgr_dart_example.dart`](mcumgr_dart_example.dart)

A self-contained `SmpTransport` that answers the OS-group **echo** in-process,
driven through the real `SmpClient` + `OsMgmt`. Run it anywhere:

```bash
dart run example/mcumgr_dart_example.dart
# echo -> hello mcumgr_dart
```

## 2. Real BLE transport with `universal_ble` — [`ble_universal_ble/`](ble_universal_ble/)

A complete Flutter example: scan for SMP-enabled devices, connect, run an OS
**echo**, and list the device's firmware **images**. `universal_ble` and Flutter
are dependencies of that example package **only** — never of `mcumgr_dart`.

```bash
cd example/ble_universal_ble
flutter run
```

The whole BLE seam is one class — [`SmpBleTransport`](ble_universal_ble/lib/smp_ble_transport.dart),
which implements `SmpTransport` over the Nordic SMP GATT service. Once you have a
transport, the rest is pure `mcumgr_dart`:

```dart
final transport = SmpBleTransport(deviceId);   // your SmpTransport impl
final client = SmpClient(transport);
await transport.connect();                      // gates on the SMP service

// OS group
final os = OsMgmt(client);
print(await os.echo('hello from mcumgr_dart'));

// Image group (DFU): list slots, upload, stage, confirm
final img = ImgMgmt(client, maxWriteLength: () => transport.maxWriteLength);
for (final slot in await img.list()) {
  print('image ${slot.image} slot ${slot.slot} v${slot.version}');
}
final sha = await img.upload(firmwareBytes, onProgress: (s, t) => print('$s/$t'));
await img.test(sha);                            // boot new image once
// … device reboots, comes up healthy …
await img.confirm(sha);                         // make it permanent

// FS group: transfer files by path
final fs = FsMgmt(client, maxWriteLength: () => transport.maxWriteLength);
final bytes = await fs.download('/lfs/log/1');

await client.dispose();
await transport.disconnect();
```

See the transport source for the BLE specifics (SMP service/characteristic
UUIDs, MTU handling for upload chunking, notification reassembly is handled by
`SmpClient`).
