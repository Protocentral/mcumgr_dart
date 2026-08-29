// Copyright (c) 2024 ProtoCentral
// SPDX-License-Identifier: MIT

import '../smp/smp_client.dart';
import '../smp/smp_message.dart';

/// One statistics group read back from a device: its name and its counters.
///
/// Zephyr's statistics are monotonic unsigned counters (`STATS_SECT_ENTRY`
/// 16/32/64-bit), so every value is an [int]. A device that reports something
/// else has a non-stock stats implementation; [fields] keeps only the entries
/// that decoded as integers, and [rawFields] preserves everything as received so
/// nothing is silently lost.
class StatGroup {
  const StatGroup({
    required this.name,
    required this.fields,
    required this.rawFields,
  });

  /// The group name, as passed to [StatMgmt.show].
  final String name;

  /// Counter name to value, for every entry that decoded as an integer.
  final Map<String, int> fields;

  /// Every entry exactly as decoded, including any that were not integers.
  final Map<String, Object?> rawFields;

  /// Counters whose value did not decode as an integer, if any.
  Iterable<String> get nonIntegerFields =>
      rawFields.keys.where((k) => !fields.containsKey(k));

  @override
  String toString() => 'StatGroup($name, ${fields.length} fields)';
}

/// MCUmgr **Statistics management group** (group id 2).
///
/// Reads Zephyr's `stats` counters — the per-subsystem tallies registered with
/// `STATS_SECT_DECL` / `STATS_NAME`. Two commands, both read-only: [list] to
/// enumerate the groups a device exposes, and [show] to read one group's
/// counters.
///
/// This group is **read-only by design**: MCUmgr has no command to reset a
/// counter, so a client can observe but never clear. Rates must be derived by
/// sampling [show] twice and differencing — the device does not do it for you.
///
/// Requires `CONFIG_MCUMGR_GRP_STAT=y` (which depends on `CONFIG_STATS`) on the
/// device. Without it every call throws with `MGMT_ERR_ENOTSUP` (rc 8), which is
/// a verdict — the device answered and said it has no such group. A *timeout* is
/// not: it tells you nothing about the firmware.
///
/// ```dart
/// final stats = StatMgmt(client);
/// for (final name in await stats.list()) {
///   final g = await stats.show(name);
///   print('$name: ${g.fields}');
/// }
/// ```
class StatMgmt {
  StatMgmt(this.client);

  final SmpClient client;

  static const int group = 2;

  /// Read one group's counters.
  static const int idShow = 0;

  /// Enumerate the available group names.
  static const int idList = 1;

  /// Throw an [SmpException] if [rsp] carries a non-zero MCUmgr result code
  /// (SMP v1 `rc` or SMP v2 `err`), with a human-readable label.
  SmpMessage _check(SmpMessage rsp) {
    final code = rsp.rc;
    if (code != null) {
      throw SmpException(
          rsp.errorLabel ?? 'rc=$code', rsp.group, rsp.id, rsp.seq,
          rc: code);
    }
    return rsp;
  }

  /// List the statistics group names the device exposes.
  ///
  /// Returns an empty list when the device has no registered groups — which is
  /// a real answer, and different from the throw you get when the whole group is
  /// not compiled in.
  Future<List<String>> list() async {
    final rsp = _check(await client.send(
      op: SmpOp.readReq,
      group: group,
      id: idList,
    ));
    final raw = rsp.payload['stat_list'];
    if (raw is! List) return const [];
    // Skip anything that is not a string rather than throwing: one malformed
    // entry must not cost the caller the whole list.
    return [
      for (final e in raw)
        if (e is String) e
    ];
  }

  /// Read the counters in the group named [name].
  ///
  /// Throws if the device does not know the name — Zephyr answers
  /// `STAT_MGMT_ERR_INVALID_GROUP` (rc 2 in the group-2 namespace), surfaced as
  /// `stats: unknown group name`.
  Future<StatGroup> show(String name) async {
    final rsp = _check(await client.send(
      op: SmpOp.readReq,
      group: group,
      id: idShow,
      payload: {'name': name},
    ));

    final rawFields = <String, Object?>{};
    final fields = <String, int>{};
    final f = rsp.payload['fields'];
    if (f is Map) {
      for (final entry in f.entries) {
        final k = entry.key.toString();
        rawFields[k] = entry.value;
        final v = entry.value;
        if (v is int) fields[k] = v;
      }
    }

    return StatGroup(
      // Prefer the echoed name; fall back to what we asked for, so the result
      // is always attributable even on firmware that omits it.
      name:
          rsp.payload['name'] is String ? rsp.payload['name'] as String : name,
      fields: fields,
      rawFields: rawFields,
    );
  }

  /// Read every group the device exposes, keyed by name.
  ///
  /// Convenience over [list] + [show]. Sequential on purpose: SMP has one
  /// outstanding request per sequence number and devices are small, so firing
  /// these concurrently gains little and risks exhausting the device's buffers.
  Future<Map<String, StatGroup>> showAll() async {
    final out = <String, StatGroup>{};
    for (final name in await list()) {
      out[name] = await show(name);
    }
    return out;
  }
}
