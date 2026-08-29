// Copyright (c) 2024 ProtoCentral
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import '../smp/smp_client.dart';
import '../smp/smp_message.dart';

/// The value of one setting, as raw bytes plus whether the device truncated it.
///
/// Zephyr stores settings as **opaque byte arrays** — the settings subsystem has
/// no type information to report, so neither does this. Decoding is the caller's
/// job, because only the caller knows what the firmware wrote; see [asInt],
/// [asString] and friends for the common cases.
class SettingValue {
  const SettingValue({required this.bytes, this.maxSize});

  /// The value exactly as the device returned it.
  final Uint8List bytes;

  /// The device's per-value read limit, present **only when the real value was
  /// longer than it** — i.e. when [bytes] is a truncated prefix.
  ///
  /// Zephyr signals truncation by adding `max_size` to an otherwise ordinary
  /// success response (`CONFIG_MCUMGR_GRP_SETTINGS_VALUE_LEN`). It is not an
  /// error, so a client that ignores it reads a short value as a complete one —
  /// which is why [truncated] exists rather than leaving callers to notice.
  final int? maxSize;

  /// Whether [bytes] is a prefix of the real value rather than the whole of it.
  bool get truncated => maxSize != null;

  int get length => bytes.length;

  /// Decode as a little-endian integer of [bytes]'s own width (1/2/4/8 bytes).
  ///
  /// **Assumes little-endian**, which is right for Arm and RISC-V Zephyr targets
  /// and wrong on a big-endian one. Returns null if the width is not 1, 2, 4 or
  /// 8, or if the value was [truncated] — a truncated integer is a wrong number,
  /// not a partial one, and silently returning it would be worse than nothing.
  int? asInt({bool signed = false}) {
    if (truncated) return null;
    final b = ByteData.sublistView(bytes);
    switch (bytes.length) {
      case 1:
        return signed ? b.getInt8(0) : b.getUint8(0);
      case 2:
        return signed
            ? b.getInt16(0, Endian.little)
            : b.getUint16(0, Endian.little);
      case 4:
        return signed
            ? b.getInt32(0, Endian.little)
            : b.getUint32(0, Endian.little);
      case 8:
        return signed
            ? b.getInt64(0, Endian.little)
            : b.getUint64(0, Endian.little);
      default:
        return null;
    }
  }

  /// Decode as a bool: a single byte, false iff zero. Null on any other width.
  bool? asBool() {
    if (truncated || bytes.length != 1) return null;
    return bytes[0] != 0;
  }

  /// Decode as UTF-8, dropping one trailing NUL if the firmware stored one.
  ///
  /// Returns null on invalid UTF-8 rather than throwing or substituting
  /// replacement characters — a setting that will not decode is a fact the
  /// caller should see, not paper over. A [truncated] value is still decoded:
  /// unlike an integer, a short string is a partial string, and the flag says so.
  String? asString() {
    var b = bytes;
    if (b.isNotEmpty && b.last == 0) b = b.sublist(0, b.length - 1);
    try {
      return const Utf8Decoder(allowMalformed: false).convert(b);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() =>
      'SettingValue(${bytes.length} bytes${truncated ? ", TRUNCATED at $maxSize" : ""})';
}

/// MCUmgr **Settings management group** (group id 3), also called "config".
///
/// Reads and writes entries in Zephyr's settings subsystem by name (e.g.
/// `bt/name`, `app/led`), and drives its persistence: [commit] applies staged
/// values at runtime, [save] writes them to the backing store, [load] re-reads
/// them from it.
///
/// **Values are opaque bytes both ways.** The settings subsystem carries no type
/// information, so this API cannot invent any: [read] hands back a
/// [SettingValue] and the caller decodes it, knowing what the firmware wrote.
/// The convenience encoders ([writeInt], [writeString], [writeBool]) and
/// decoders on [SettingValue] cover the usual cases and document their
/// assumptions; anything else, build the bytes yourself.
///
/// Requires `CONFIG_MCUMGR_GRP_SETTINGS=y` on the device, which in turn needs
/// `CONFIG_SETTINGS` **and** `CONFIG_SETTINGS_RUNTIME` — the latter is easy to
/// miss, and without it the group will not build. If the group is absent, calls
/// throw with `MGMT_ERR_ENOTSUP` (rc 8), which is a verdict about the firmware;
/// a timeout is not.
///
/// ```dart
/// final settings = SettingsMgmt(client);
/// final v = await settings.read('app/brightness');
/// print(v.asInt());
/// await settings.writeInt('app/brightness', 80, width: 1);
/// await settings.commit();   // apply now
/// await settings.save();     // persist across reboot
/// ```
class SettingsMgmt {
  SettingsMgmt(this.client);

  final SmpClient client;

  static const int group = 3;

  /// Read (read op) / write (write op) one setting.
  static const int idReadWrite = 0;

  /// Delete one setting.
  static const int idDelete = 1;

  /// Commit staged settings — apply them at runtime.
  static const int idCommit = 2;

  /// Load (read op) / save (write op) settings against the backing store.
  static const int idLoadSave = 3;

  SmpMessage _check(SmpMessage rsp) {
    final code = rsp.rc;
    if (code != null) {
      throw SmpException(
          rsp.errorLabel ?? 'rc=$code', rsp.group, rsp.id, rsp.seq,
          rc: code);
    }
    return rsp;
  }

  /// Read the setting named [name].
  ///
  /// [maxSize] caps how many bytes the device reads back; omit it to let the
  /// device use its own limit. Either way, check [SettingValue.truncated] — the
  /// device reports a short read as a success, not an error.
  ///
  /// Throws when the key does not exist (`key not found`), when its root does
  /// not (`root key not found`), or when the firmware declines to expose it
  /// (`read not supported`).
  Future<SettingValue> read(String name, {int? maxSize}) async {
    final rsp = _check(await client.send(
      op: SmpOp.readReq,
      group: group,
      id: idReadWrite,
      payload: {
        'name': name,
        if (maxSize != null) 'max_size': maxSize,
      },
    ));

    final raw = rsp.payload['val'];
    final bytes = switch (raw) {
      Uint8List b => b,
      List<int> l => Uint8List.fromList(l),
      List<Object?> l => Uint8List.fromList(l.whereType<int>().toList()),
      _ => Uint8List(0),
    };

    // Present only when the value was longer than the device's read limit.
    final limit = rsp.payload['max_size'];
    return SettingValue(
      bytes: bytes,
      maxSize: limit is int ? limit : null,
    );
  }

  /// Write raw [value] bytes to the setting named [name].
  ///
  /// This changes the value **in memory only**. Call [commit] to apply it and
  /// [save] to persist it across a reboot; a write alone does neither, and that
  /// is the most common surprise with this group.
  Future<void> write(String name, Uint8List value) async {
    _check(await client.send(
      op: SmpOp.writeReq,
      group: group,
      id: idReadWrite,
      payload: {'name': name, 'val': value},
    ));
  }

  /// Write [value] as a little-endian integer [width] bytes wide (1, 2, 4 or 8).
  ///
  /// The width must match what the firmware expects — there is no negotiation
  /// and no way to discover it, so a mismatch writes a value the device will
  /// misread. See [write] regarding [commit] and [save].
  Future<void> writeInt(String name, int value, {int width = 4}) {
    final b = ByteData(width);
    switch (width) {
      case 1:
        b.setUint8(0, value & 0xFF);
      case 2:
        b.setUint16(0, value & 0xFFFF, Endian.little);
      case 4:
        b.setUint32(0, value & 0xFFFFFFFF, Endian.little);
      case 8:
        b.setInt64(0, value, Endian.little);
      default:
        throw ArgumentError.value(width, 'width', 'must be 1, 2, 4 or 8');
    }
    return write(name, b.buffer.asUint8List());
  }

  /// Write [value] as a single byte, 1 or 0.
  Future<void> writeBool(String name, bool value) =>
      write(name, Uint8List.fromList([value ? 1 : 0]));

  /// Write [value] as UTF-8.
  ///
  /// [nullTerminated] appends a trailing NUL, which firmware that reads the
  /// value straight into a C string will expect. It defaults to false because
  /// the settings subsystem stores a length, and an unwanted NUL becomes part of
  /// the value.
  Future<void> writeString(String name, String value,
          {bool nullTerminated = false}) =>
      write(
        name,
        Uint8List.fromList(
            nullTerminated ? [...utf8.encode(value), 0] : utf8.encode(value)),
      );

  /// Delete the setting named [name].
  Future<void> delete(String name) async {
    _check(await client.send(
      op: SmpOp.writeReq,
      group: group,
      id: idDelete,
      payload: {'name': name},
    ));
  }

  /// Commit staged settings — apply written values at runtime.
  ///
  /// Does **not** persist them; that is [save]. A device may reject this if a
  /// staged value fails its own validation.
  Future<void> commit() async {
    _check(await client.send(
      op: SmpOp.writeReq,
      group: group,
      id: idCommit,
    ));
  }

  /// Reload settings from the backing store, discarding uncommitted changes.
  Future<void> load() async {
    _check(await client.send(
      op: SmpOp.readReq,
      group: group,
      id: idLoadSave,
    ));
  }

  /// Persist settings to the backing store.
  ///
  /// With [name] omitted the whole tree is saved. With [name] given, only that
  /// subtree is — Zephyr rejects an empty string, so pass null rather than `''`
  /// to mean "everything".
  Future<void> save({String? name}) async {
    if (name != null && name.isEmpty) {
      throw ArgumentError.value(
          name, 'name', 'must be null to save everything, not empty');
    }
    _check(await client.send(
      op: SmpOp.writeReq,
      group: group,
      id: idLoadSave,
      payload: {if (name != null) 'name': name},
    ));
  }
}
