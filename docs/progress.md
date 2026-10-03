# FieldLens progress

Last reviewed: 2026-10-03

The local mobile foundation and inspection-draft milestone are verified. The complete product remains in development.

## Delivered

- Flutter 3.35.7, Riverpod composition, persistent background Drift/SQLite, structured diagnostics, and build-time demo configuration.
- Two Factory Demo sites, five industrial assets and assignments, reactive work-order lists and local queued-change counts.
- Schema-driven draft editing, type/required validation, autosave, failed-save retry, and review that is invalidated by subsequent edits.
- Immutable per-draft template snapshots, stable inspection/answer/operation UUIDs, transactional local writes and full outbox snapshots.
- Monotonic outbox replay sequences. The v1-to-v2 migration preserves old operations and payloads while adding draft tables and rebuilding outbox ordering safely.
- Frozen schema snapshots, independent migration/repository review, CI configuration, six ADRs, and reusable cloud setup/start instructions.

## Verification

| Check | Result |
|---|---|
| Combined cloud setup, including locked dependencies and Android prerequisites | Passed; repeat run completed |
| Drift generation and frozen v2 schema comparison | Passed |
| Formatting | Passed; no changes required |
| Flutter analysis | Passed; no issues |
| Entire Flutter test suite | 59 passed |
| Independent draft/migration review | 9 targeted tests passed; material findings corrected |
| Android debug APK | Built successfully |
| Asset identification | 11 repository and 10 widget/platform-fake tests passed |
| Physical-camera acceptance | Unrun; no device attached, widget tests inject scan values |
| Hosted GitHub Actions | Configured; not executed remotely |
| Physical-device force-close/camera/offline-to-server E2E | Unrun; no attached device or emulator, capture/backend/sync are not implemented |

Tests cover local serial ambiguity, malformed/aliased QR rejection, stale-result invalidation, delayed scanner start/stop/disposal, reactive persistence, atomic rollback, reopening file databases, data-preserving migration, sequence non-reuse, schema validation, navigation, queued-change UI, autosave failures, rapid multiple-choice edits, and invalidation of a previously valid review.

## Roadmap

| Phase | State |
|---|---|
| 1 — Foundation | Verified for local development and Android packaging |
| 2 — Offline asset/work-order experience | Demo sites/assets/assignments/list implemented; authenticated scoping awaits Phase 6 |
| 3 — Inspection engine | Durable validated drafts verified; actual photo/signature capture and final submission remain pending |
| 4 — Asset identification | Local serial search, strict QR resolution, and camera/manual fallback UI implemented; physical-camera acceptance unrun |
| 5 — Evidence pipeline | Pending |
| 6 — Auth/cloud backend/security | Pending |
| 7 — Synchronization | Durable outbox foundation present; transport, retry, media transfer and pull pending |
| 8 — Conflicts/reliability | Local ordering and migration safety verified; server revisions and recovery protocol pending |
| 9 — On-device AI | Pending |
| 10 — Supervisor console | Pending |
| 11 — Operations | Pending |
| 12 — Production/portfolio | Initial CI/tests/architecture present; release signing, security validation and portfolio work pending |

## Next milestone and limitations

Asset identification searches exact serial values on-device after trimming whitespace and ignoring case. Duplicate matches are all listed in stable site/asset-tag order for technician selection. QR resolution is local and strict: it accepts `FIELDLENS://ASSET/<identifier>`, ignores case in scheme/host, preserves identifier case, and rejects malformed URIs, extra path segments, query/fragment data, ports, user information, and percent-encoded identifiers. Duplicate stored codes after scheme/host normalization produce an explicit ambiguity error instead of selecting an asset. The `mobile_scanner` package uses a bundled on-device ML Kit barcode model. On camera startup failure, the scanner provides manual QR payload entry; serial search is available separately. Widget tests inject values and do not verify the native camera, which remains untested without an attached device.

Proceed to filesystem-backed evidence capture after asset-identification review and appropriate verification. Preserve the template snapshot, transaction, and outbox contracts. Demo assignments are not authenticated production records; no queued operation has synchronized to a server. Photo and signature controls are placeholders, and submission is unavailable. The setup/start configuration remains a draft; publication and restoration in a new task have not been verified.

The cloud machine has no device runtime. Its ADB also cannot create its default home configuration under the current filesystem sandbox; device validation needs supported device access. Debug builds work; production signing is unconfigured. Setup and start instructions are saved as a configuration draft. Publication and restoration in a new task have not been verified.
