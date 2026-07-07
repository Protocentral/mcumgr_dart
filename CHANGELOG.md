# Changelog

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
