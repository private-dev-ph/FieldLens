# FieldLens milestone checklist

Update this checklist when a milestone starts, after verification, and before ending a session. Check code and Git state before trusting a checkpoint. Checked implementation items do not imply physical-device or hosted verification.

## Resume checkpoint

- Latest completed milestone: **Phase 5 — durable photo evidence**, verified for local development and Android packaging.
- Next milestone: **Phase 3 completion — signed offline submission**; implementation has not started.
- Local branch: `work`, tracking `origin/main`. Evidence milestone: `f5b5048`; earlier checkpoints: `abe3233`, `1a3a54e` and `1ea83c4`.
- GitHub: history pushed to `private-dev-ph/FieldLens` on `main`; remote evidence commit verified on 2026-10-03. Confirm later changes with Git status/log.
- Verified: **102 tests**, frozen dependencies, Drift generation/fresh v3 schema comparison, formatting, analysis, independent review and final Android debug APK.
- Expected uncommitted work after the milestone commit: none. Always inspect Git status and preserve later user changes.
- No device/emulator provisioned. Hosted CI, onboarding environment publication/new-task restoration and full offline-to-server E2E remain unverified. Backend/auth/sync transport are not implemented.

Read `AGENTS.md`, this checklist, `progress.md`, the project plan and relevant ADRs. Agents and shell sessions may not survive a cut; inspect files and running processes before resuming or reassigning work.

```sh
cd /workspace/FieldLens
git status --short
git log -5 --oneline
source scripts/cloud-env.sh
cd apps/mobile
```

Next: define the signature artifact, ownership/content binding and submission contract before parallel implementation. Store signature bytes outside SQLite, validate actual artifacts rather than UUID shape, and require final attestation even for existing templates without a signature field. Preserve immutable draft templates. Final submission must validate evidence, freeze edits, complete the work order and queue replayable operations atomically and idempotently. Then delegate migration/repository, file storage and UI against those settled contracts, independently review and verify. No schema generation or build workstream remains active at this checkpoint.

## 1 — Local foundation

- [x] Flutter/Riverpod configuration and persistent background Drift database.
- [x] Reactive repositories, UUID identities, transactional outbox and structured logging.
- [x] Local asset/work-order acceptance, cloud setup, tests/analysis/debug APK and foundational ADRs.

## 2 — Offline assignments and Factory Demo

- [x] Two sites, five industrial assets, local assignments and reactive dashboard.
- [x] Visible local queue and development without a remote backend.
- [ ] Authenticated account/organization scoping (Phase 6 dependency).

## 3 — Inspection engine

- [x] Typed schema-driven fields, validation and immutable template snapshots.
- [x] Durable draft/answer persistence, autosave/retry/review and host interruption tests.
- [x] Photo controls integrated and verified in Phase 5.
- [ ] Signed offline submission milestone: define signature artifact/ownership and finalization contracts.
- [ ] Additive signature metadata migration and file-backed capture/recovery; reject arbitrary UUIDs.
- [ ] Signature controls and immutable, idempotent local submission with completed work order and atomic outbox.
- [ ] Submission rollback/reopen/integrity tests and independent review.
- [ ] Physical-device force-close/reopen acceptance.

## 4 — Offline asset identification

- [x] Local serial lookup/ambiguity and strict QR resolution/alias rejection.
- [x] Bundled QR-only scanner, manual fallback and asset-to-draft navigation.
- [x] Independent review, 59-test aggregate, analysis and debug APK.
- [ ] Physical-device airplane-mode QR acceptance.

## 5 — Evidence pipeline

- [x] Shared filesystem/metadata/capture contracts.
- [x] JPEG preservation, checksums, thumbnails, limits/path guards and file-store review; 11 real-filesystem tests pass, including oversized-thumbnail repair.
- [x] Additive v3 media table and capture repository implementation present.
- [x] Camera route/platform-fake tests and app-private bootstrap/recovery wiring present.
- [x] Photo controls, thumbnails, unavailable-evidence feedback/removal and checksum review integrated; original 7 widget tests independently pass.
- [x] Legacy unresolved references preserved honestly; new-reference ownership and no-op validation tested.
- [x] Camera lifecycle/error/retry reviewed; 9 platform-fake tests pass.
- [x] Independent transaction/recovery/migration review accepted after fixes; partial writes and transient storage errors remain recoverable.
- [x] Locked dependencies and fresh v3 schema comparison pass.
- [x] Data-preserving migrations create the media index; missing-index and random-ID test findings corrected. Repository/migration workstream passes 25 focused tests; reviewer independently reran affected cases.
- [x] Locked dependencies/generation/formatting/analysis/entire suite pass: 102 tests.
- [x] Debug APK and merged permissions verified: no microphone/storage permissions, optional camera hardware, three bundled barcode models. Final rebuild includes the settled form source.
- [x] ADR/architecture/progress/checklist updated and included in the coherent evidence milestone commit.
- [ ] Physical-device capture/restart acceptance.

Run after implementation settles; record actual results before checking verification items:

```sh
flutter pub get --enforce-lockfile
dart run build_runner build
dart run drift_dev schema dump lib/database/app_database.dart /tmp/fieldlens-schema
diff drift_schemas/drift_schema_v3.json /tmp/fieldlens-schema/drift_schema_v3.json
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test --reporter expanded --timeout 30s
flutter build apk --debug
```

## 6 — Authentication and cloud backend

- [ ] Supabase Auth/account lifecycle and authenticated local scoping.
- [ ] PostgreSQL/Storage migrations, role/organization contracts and RLS tests.
- [ ] Expiration/offline behavior and storage isolation verification.

## 7 — Synchronization

- [x] Durable ordered operation outbox foundation.
- [ ] Client/server operation/idempotency contracts, dependency-ordered media/push/pull.
- [ ] Retries/backoff/recovery, startup/resume/connectivity/manual triggers and visible state.
- [ ] Defining offline-to-server E2E passes.

## 8 — Conflicts and reliability

- [x] Local sequence ordering/non-reuse and migration preservation tests.
- [ ] Server revisions, expected-revision writes, conflicts and actionable issue UI.
- [ ] Retry classification and termination/partial-upload/auth-expiration stress tests.

## 9 — On-device AI

- [ ] Packaged ONNX model/provenance and post-capture preprocessing/inference/postprocessing.
- [ ] Bounding boxes and technician verdict separate from prediction.
- [ ] Deterministic processing and device tests.

## 10 — Supervisor console

- [ ] Next.js secure access and sites/assets/technicians/templates/assignments.
- [ ] Inspection/evidence/AI review and configured lint/type/tests/production build.

## 11 — Operations

- [ ] Audit/diagnostics/export and model releases.
- [ ] Secure logout/device reset and reference-aware stale-media cleanup.

## 12 — Production and portfolio

- [x] Initial CI/local tests/architecture/ADRs.
- [ ] Hosted CI/migration/security checks, release signing/builds and threat model.
- [ ] Full E2E evidence, screenshots/demo/diagrams and portfolio-showcase.json.
- [ ] Published onboarding configuration and new-task restoration verified.
