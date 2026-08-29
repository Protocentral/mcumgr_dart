// Copyright (c) 2024 ProtoCentral
// SPDX-License-Identifier: MIT

/// A pure-Dart client for the **Simple Management Protocol (SMP)** and the
/// **MCUmgr** management groups used by Zephyr / MCUboot devices.
///
/// Transport-agnostic: bring your own byte transport (BLE, serial, TCP) by
/// implementing [SmpTransport]; everything above it — request/response matching,
/// fragment reassembly, and the OS / Image / FS management facades — is plain
/// Dart with no Flutter dependency.
///
/// For a byte stream rather than a GATT characteristic, [UartMcumgrCodec] and
/// [UartMcumgrDecoder] provide Zephyr's `uart_mcumgr` encapsulation, so a
/// serial or TCP transport only has to move bytes.
///
/// ```dart
/// final client = SmpClient(myTransport);
/// final os = OsMgmt(client);
/// print(await os.echo('hello'));            // OS group
///
/// final img = ImgMgmt(client, maxWriteLength: () => myTransport.maxWriteLength);
/// final sha = await img.upload(firmware, onProgress: (s, t) => print('$s/$t'));
/// await img.test(sha);                       // Image group (DFU)
///
/// final fs = FsMgmt(client, maxWriteLength: () => myTransport.maxWriteLength);
/// final bytes = await fs.download('/lfs/log/1');  // FS group
///
/// final stats = StatMgmt(client);
/// print(await stats.list());                 // Statistics group
///
/// final settings = SettingsMgmt(client);
/// print((await settings.read('app/led')).asInt());   // Settings group
/// ```
library mcumgr_dart;

// SMP core
export 'src/smp/smp_message.dart';
export 'src/smp/smp_transport.dart';
export 'src/smp/uart_mcumgr_codec.dart';
export 'src/smp/smp_client.dart';

// MCUmgr management groups
export 'src/mcumgr/os_mgmt.dart';
export 'src/mcumgr/img_mgmt.dart';
export 'src/mcumgr/fs_mgmt.dart';
export 'src/mcumgr/stat_mgmt.dart';
export 'src/mcumgr/settings_mgmt.dart';
