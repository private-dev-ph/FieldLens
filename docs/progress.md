# FieldLens progress

Last reviewed: 2026-10-03

The [milestone checklist](milestones.md) records every phase, acceptance checks and cut-session resume instructions. The latest completed milestone is durable offline photo evidence (`f5b5048`), published to GitHub on `main`. The next milestone completes signatures and local submission before cloud integration.

## Delivered

- Flutter 3.35.7/Riverpod application, persistent background Drift/SQLite, structured diagnostics and reusable cloud toolchains.
- Two local Factory Demo sites, five industrial assets and assignments, reactive work lists and queued-change counts.
- Schema-driven validated drafts, immutable template snapshots, stable UUID answer records, autosave/retry/review and transactional outbox snapshots.
- Offline serial search with ambiguity handling; strict local QR resolution and a bundled QR-only camera scanner with manual fallback.
- App-private original JPEGs, thumbnails, checksums, dimensions and capture metadata outside SQLite. Photo controls show local saving state, previews and unavailable evidence.
- Durable capture intents, atomic media/answer/outbox completion, partial-write and termination recovery APIs, integrity checks and retryable storage errors. Review checks photo ownership, state, lengths and hashes. Removing an unavailable reference changes the current answer while retaining files and earlier queued snapshots.
- Additive database v3 migrations preserve existing data, template snapshots and outbox ordering; upgraded databases receive the media index. Demo template revision 2 adds an optional photo item only for new drafts.
- CI configuration, frozen schemas and foundational ADRs. ADR 0003 documents file/database recovery boundaries.

## Verification

| Check | Result |
|---|---|
| Repeatable cloud setup and locked dependencies | Passed |
| Drift generation and fresh frozen v3 schema comparison | Passed |
| Formatting and Flutter analysis | Passed; no issues |
| Entire Flutter test suite | **102 passed** |
| Independent repository/migration/filesystem review | Accepted after fixes; targeted tests passed |
| Independent inspection form and photo integration checks | 7 existing widget tests and 7 new integration tests passed |
| Camera lifecycle/platform-fake suite | 9 passed; native hardware untested |
| Final Android debug APK | Built successfully |
| Actual APK permissions and models | No microphone/storage permissions; camera hardware optional; three barcode models bundled |
| Hosted GitHub Actions | Configured; unrun |
| Physical-device camera/airplane-mode/force-close checks | Unrun; no attached device or emulator |
| Full offline-to-server E2E | Unrun; backend/sync transport not implemented |
| Onboarding publication/new-task restoration | Setup/start draft saved; publication/restoration unverified |

Tests exercise persistence and database reopen, migration preservation/index creation, transactional rollback, UUID ownership, ordered outbox snapshots, capture cancellation and partial writes, recovery after transient filesystem errors, thumbnail repair, legacy-reference retention/removal, same-length evidence corruption, form navigation guards, QR parsing/ambiguity and camera lifecycle races. Widget capture callbacks and camera platform fakes do not establish native-device behavior.

## Remaining work

Signature capture and final local submission are the next prerequisite. The signing contract must require valid local artifacts and final attestation for legacy drafts, preserve immutable templates, and prevent stale signatures after answers change. Submission must validate evidence, freeze editing, complete the work order and queue its final snapshots atomically and idempotently.

Authenticated organization scoping, Supabase/PostgreSQL/Storage/RLS, sync transport/retries/conflicts, ONNX inference, the supervisor console and operational/release features remain unimplemented. Demo assignments are not authenticated production records; no queued operation has synchronized to a server. Reference-aware media cleanup is deferred; retained evidence is not eagerly deleted.

The APK is a debug build at `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`; production signing is unconfigured. This cloud sandbox has no device runtime and prevents ADB from creating its default home configuration. Supported device access is required for hardware acceptance. Environment setup/start instructions are saved as a draft; the product owns publication and restoration.
