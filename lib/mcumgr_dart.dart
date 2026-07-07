/// A pure-Dart client for the **Simple Management Protocol (SMP)** and the
/// **MCUmgr** management groups used by Zephyr / MCUboot devices.
///
/// Transport-agnostic: bring your own byte transport (BLE, serial, TCP) by
/// implementing [SmpTransport]; everything above it — request/response matching,
/// fragment reassembly, and the OS / Image / FS management facades — is plain
/// Dart with no Flutter dependency.
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
/// ```
library mcumgr_dart;

// SMP core
export 'src/smp/smp_message.dart';
export 'src/smp/smp_transport.dart';
export 'src/smp/smp_client.dart';

// MCUmgr management groups
export 'src/mcumgr/os_mgmt.dart';
export 'src/mcumgr/img_mgmt.dart';
export 'src/mcumgr/fs_mgmt.dart';
