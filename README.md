# mcumgr_dart

[![pub package](https://img.shields.io/pub/v/mcumgr_dart.svg)](https://pub.dev/packages/mcumgr_dart)
[![pub points](https://img.shields.io/pub/points/mcumgr_dart)](https://pub.dev/packages/mcumgr_dart/score)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A pure-Dart client for the **Simple Management Protocol (SMP)** and the
**MCUmgr** management groups used by [Zephyr](https://www.zephyrproject.org/) /
[MCUboot](https://www.mcuboot.com/) devices.

## Features

- **Transport-agnostic.** Bring your own byte transport — BLE, serial, or TCP —
  by implementing a small interface. Everything above it is plain Dart.
- **Byte streams included.** For serial or TCP, `UartMcumgrCodec` implements
  Zephyr's `uart_mcumgr` framing, so the transport only has to move bytes.
- **No Flutter dependency.** Runs anywhere Dart runs (Flutter apps, CLI tools,
  servers). Depends only on `cbor` and `crypto`.
- **All platforms:** iOS · Android · macOS · Windows · Linux · Web — no native
  code, no platform channels.
- **Batteries included** for the common groups: **OS** (echo, datetime, reset),
  **Image** (the DFU upload/test/confirm flow), **Filesystem** (file
  download/upload/stat), **Statistics** (list/show counters) and **Settings**
  (read/write/delete/commit/save). Vendor groups are easy to add.
- **Testable without hardware** — `SmpClient` runs over any transport, including
  an in-process loopback (see the example).

Extracted from the [ProtoCentral](https://protocentral.com) OpenView 3 and
HealthyPi Move apps, where it drives BLE firmware updates and health-data file
transfer over MCUmgr.

## Install

```bash
dart pub add mcumgr_dart
```

or add it to `pubspec.yaml`:

```yaml
dependencies:
  mcumgr_dart: ^0.1.0
```

## Concepts

```
your transport (BLE / serial / TCP)   ← you implement SmpTransport
        │  raw bytes
        ▼
     SmpClient        ← seq matching · fragment reassembly · timeouts
        │  SmpMessage (8-byte header + CBOR)
        ▼
 OsMgmt · ImgMgmt · FsMgmt   ← typed management-group facades
```

`SmpClient` speaks framed SMP messages over any `SmpTransport`. The management
facades (`OsMgmt`, `ImgMgmt`, `FsMgmt`) wrap a client and expose typed calls.

## Implementing a transport

`SmpClient` needs a byte pipe that can send a framed request and stream inbound
notifications (which may be fragmented — the client reassembles them). A minimal
skeleton:

```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:mcumgr_dart/mcumgr_dart.dart';

class MyTransport implements SmpTransport {
  final _rx = StreamController<Uint8List>.broadcast();
  final _states = StreamController<SmpConnectionState>.broadcast();
  var _state = SmpConnectionState.disconnected;

  @override
  String? get deviceLabel => 'my-device';

  @override
  SmpConnectionState get state => _state;

  @override
  Stream<SmpConnectionState> get stateChanges => _states.stream;

  @override
  Stream<Uint8List> get notifications => _rx.stream;

  @override
  int? get maxWriteLength => 244; // e.g. ATT MTU − 3

  @override
  Future<void> connect() async {
    // open the link, resolve the SMP characteristic, subscribe to notifications,
    // and feed each inbound packet to `_rx.add(...)`.
  }

  @override
  Future<void> write(Uint8List frame) async {
    // write one framed SMP request (write-without-response for BLE).
  }

  @override
  Future<void> disconnect() async {
    // tear down and _state = SmpConnectionState.disconnected;
  }
}
```

For BLE, a good pattern is [`universal_ble`](https://pub.dev/packages/universal_ble):
gate on the SMP service `8d53dc1d-1db7-4cd3-868b-8a527460aa84`, subscribe to its
characteristic, and forward notifications to the `notifications` stream.

### Byte-stream transports (serial, TCP)

On BLE the bytes on the characteristic *are* the SMP frame. A byte stream has no
packet boundaries, so Zephyr's `uart_mcumgr` transport wraps each frame in a
length prefix, a CRC-16/XMODEM and base64 lines marked `0x06 0x09` (start) or
`0x04 0x14` (continuation). `UartMcumgrCodec` implements exactly that, leaving
the transport with nothing to do but move bytes:

```dart
final _decoder = UartMcumgrDecoder();

@override
Future<void> write(Uint8List frame) async {
  for (final line in UartMcumgrCodec.encode(frame)) {
    port.write(line);           // SerialPort, Socket, anything byte-oriented
  }
}

// Feed whatever the stream hands you — partial lines, several at once,
// interleaved console text — and forward whole frames to `notifications`.
void _onBytes(Uint8List chunk) {
  for (final frame in _decoder.add(chunk)) {
    _rx.add(frame);
  }
}
```

The decoder is forgiving by design, because a device's console log usually
shares the pipe: an unmarked line is skipped, and a packet that fails its length
or CRC check is dropped rather than thrown — so one bad packet cannot wedge the
stream. Both are counted in `badFrames`. Accumulation is bounded by
`maxPacketBytes` (default 4096), so a device that opens a packet and never
finishes it cannot grow the buffer without limit. Call `reset()` on reconnect so
a truncated packet cannot merge into the next session. `encode()` emits one line
per frame by default; pass `maxLineLength` to split across continuation lines.

`maxWriteLength` still matters: it bounds `ImgMgmt`'s upload chunks, so set it so
one framed line fits the device's receive buffer.

## Usage

```dart
final client = SmpClient(myTransport);
await myTransport.connect();

// OS group — echo smoke test, set the RTC, reboot.
final os = OsMgmt(client);
print(await os.echo('hello'));           // -> hello
await os.setDatetime(DateTime.now());
// await os.reset();

// Image group — DFU: upload a signed image, stage it, reboot, confirm.
final img = ImgMgmt(client, maxWriteLength: () => myTransport.maxWriteLength);
for (final slot in await img.list()) {
  print('image ${slot.image} slot ${slot.slot} v${slot.version} '
        '${slot.confirmed ? "confirmed" : "pending"}');
}
final sha = await img.upload(firmwareBytes,
    onProgress: (sent, total) => print('$sent / $total'));
await img.test(sha);     // boot the new image once
// (reboot; after it comes up healthy)
await img.confirm(sha);  // make it permanent

// Filesystem group — transfer files by absolute path.
final fs = FsMgmt(client, maxWriteLength: () => myTransport.maxWriteLength);
final size = await fs.stat('/lfs/log/1');
final bytes = await fs.download('/lfs/log/1',
    onProgress: (done, total) => print('$done / $total'));
await fs.upload('/lfs/config.bin', configBytes);
```

### Statistics (group 2)

```dart
final stats = StatMgmt(client);

for (final name in await stats.list()) {
  final group = await stats.show(name);
  print('$name -> ${group.fields}');       // { 'frame_rx': 12, ... }
}
```

### Settings (group 3)

```dart
final settings = SettingsMgmt(client);

final value = await settings.read('app/brightness');
if (value.truncated) print('device returned only ${value.length} bytes');
print(value.asInt());                       // little-endian, width from the value

await settings.writeInt('app/brightness', 80, width: 1);
await settings.commit();                    // apply at runtime
await settings.save();                      // persist across reboot
```

A write alone does neither of the last two — that is the most common surprise
with this group.

## Examples

- [`example/mcumgr_dart_example.dart`](example/mcumgr_dart_example.dart) — a
  runnable, pure-Dart **loopback** demo (no hardware): a fake device that answers
  OS-group echo. Run it with `dart run example/mcumgr_dart_example.dart`.
- [`example/ble_universal_ble/`](example/ble_universal_ble) — a complete **Flutter
  + BLE** example: scan → connect → echo + image list, using a real
  `SmpBleTransport` on [`universal_ble`](https://pub.dev/packages/universal_ble).
  (`universal_ble` is a dependency of that example only, never of this package.)

## Error handling

Non-zero MCUmgr result codes surface as `SmpException` (both SMP v1 top-level
`rc` and SMP v2 `{err: {group, rc}}` are normalised), with human-readable labels
for the generic `MGMT_ERR_*` table and the Image group. Request timeouts throw
`SmpException.timeout`. Transport-level failures throw `SmpTransportException`.

## Scope

Stock Zephyr `fs_mgmt` exposes only per-file transfer + status — there is **no
directory listing or delete** in the base group, so `FsMgmt` is a transfer-by-
path facade, not a browser. Vendor groups can extend this.

`StatMgmt` is read-only because MCUmgr is: there is no command to reset a
counter, so rates must be derived by sampling `show` twice and differencing.

`SettingsMgmt` returns **opaque bytes**, because Zephyr's settings subsystem
carries no type information to report. `SettingValue` provides `asInt`,
`asBool` and `asString` for the usual cases and documents their assumptions
(little-endian, caller-known width); anything else, decode the bytes yourself.
Note that a device signals a **truncated** read by adding `max_size` to an
otherwise ordinary success response — `SettingValue.truncated` surfaces that, so
a short value is never mistaken for a whole one.

Implemented groups: **OS** (0), **Statistics** (2), **Settings** (3),
**Image** (1), **Filesystem** (8). The Shell and Enum groups are not yet
implemented — contributions welcome.

Device-side Kconfig for the newer groups: statistics needs
`CONFIG_MCUMGR_GRP_STAT` (which depends on `CONFIG_STATS`); settings needs
`CONFIG_MCUMGR_GRP_SETTINGS`, which requires **both** `CONFIG_SETTINGS` and
`CONFIG_SETTINGS_RUNTIME` — the second is easy to miss.

## Additional information

- **Source & issues:** <https://github.com/Protocentral/mcumgr_dart>
- **Why another MCUmgr package?** The existing Dart option wraps native
  Android/iOS/macOS libraries (mobile-only, BLE-only). `mcumgr_dart` is pure
  Dart, so it also runs on **Windows, Linux, web, CLI and servers**, and lets SMP
  ride an **existing** transport instead of opening a second native BLE link.
- **Contributing:** issues and PRs are welcome — new management groups, transport
  adapters, and test coverage especially.
- **Protocol reference:** the SMP header and CBOR payload layout follow the
  [MCUmgr / SMP](https://docs.zephyrproject.org/latest/services/device_mgmt/smp_protocol.html)
  specification.

## License

[MIT](LICENSE) © ProtoCentral
