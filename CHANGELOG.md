# Changelog

## 0.2.0

Adds the two remaining read/write management groups from stock Zephyr, both
requested in [#1](https://github.com/Protocentral/mcumgr_dart/issues/1).
Purely additive — no breaking changes.

- **Statistics group (2)** — `StatMgmt.list()` enumerates the groups a device
  exposes, `show()` reads one group's counters, `showAll()` does both. Results
  come back as `StatGroup`, whose `fields` are the entries that decoded as
  integers and whose `rawFields` preserves everything as received, so a
  non-stock stats implementation loses nothing silently. Read-only, because
  MCUmgr is: there is no command to reset a counter.

- **Settings group (3)** — `SettingsMgmt` covers read/write (id 0), delete (1),
  commit (2) and load/save (3). `save({name})` saves one subtree when named and
  the whole tree when not; an empty name is rejected locally, since Zephyr
  answers `EINVAL` for it.

  Values are **opaque bytes** both ways — the settings subsystem carries no type
  information, so the API does not invent any. `SettingValue` offers `asInt`,
  `asBool` and `asString` for the common cases with their assumptions stated
  (little-endian, caller-known width), and `writeInt` / `writeBool` /
  `writeString` encode the same way.

  Truncation is handled explicitly: a device that hits
  `CONFIG_MCUMGR_GRP_SETTINGS_VALUE_LEN` returns a **short value in an ordinary
  success response**, flagged only by an extra `max_size` key. `SettingValue.truncated`
  surfaces it, and `asInt` refuses to decode a truncated value — a short integer
  is a different number, not a partial one.

- **Group-specific error names** for groups 2 and 3, so `SmpException` reads
  `settings: key not found (rc=3)` rather than `group 3 rc=3`. Previously only
  the image group had a table.

- `FakeTransport` moved to `test/fake_transport.dart` and is shared by the
  suite; both new groups are covered without hardware.

## 0.1.0

Initial release. Extracted from the ProtoCentral OpenView 3 / HealthyPi Move
apps as a standalone, pure-Dart library.

- **SMP core** — `SmpMessage` (8-byte header + CBOR, SMP v1 `rc` / v2 `err`
  normalisation and error labels), `SmpTransport` (abstract byte transport),
  `SmpClient` (rolling `seq` request/response matching, fragment reassembly,
  per-request timeout).
- **OS group** (`OsMgmt`, group 0) — echo, mcumgr params, task stat,
  datetime get/set, reset.
- **Image group** (`ImgMgmt`, group 1) — list, chunked/hashed/resumable
  `upload`, test, confirm, erase (the DFU flow).
- **FS group** (`FsMgmt`, group 8) — stat, download, upload by path.
