# FieldLens milestone checklist

Update this checklist when a milestone starts, after verification, and before ending a session. Check code and Git state before trusting a checkpoint. Checked implementation items do not imply physical-device or hosted verification.

## Resume checkpoint

- Active milestone: **Phase 5 — durable photo evidence**, integration/review in progress.
- Branch: `work`; latest verified local commit: `1a3a54e` — Add offline asset identification and QR scanning. Foundation: `1ea83c4`.
- Uncommitted work: v3 media schema/repository, file store, camera route, media bootstrap/providers, demo template revision 2, tests, Android permissions, CI and docs.
- Verified aggregate baseline: **59 tests**, formatting, analysis and Android debug APK (Phase 4). New evidence components have targeted checks; integrated Phase 5 checks remain pending.
- No device/emulator provisioned. Hosted CI, remote publication/new-task restoration and full offline-to-server E2E are unverified. Backend/auth/sync transport are not implemented.

Read `AGENTS.md`, this checklist, `progress.md`, the project plan and relevant ADRs. Preserve uncommitted changes. Agents and shell sessions may not survive a cut session; inspect files and running processes before resuming or reassigning work.

```sh
cd /workspace/FieldLens
git status --short
git log -5 --oneline
source scripts/cloud-env.sh
cd apps/mobile
```

Next: finish photo controls and unavailable-evidence review checks; review legacy-reference/recovery semantics; verify the Phase 5 checklist; update docs/checkpoint and commit. The media schema workstream currently owns Drift generation. In a resumed session, check for an existing generation process before starting another.

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
- [ ] Photo controls integrated and verified (active Phase 5 dependency).
- [ ] Signature capture and final local submission.
- [ ] Physical-device force-close/reopen acceptance.

## 4 — Offline asset identification

- [x] Local serial lookup/ambiguity and strict QR resolution/alias rejection.
- [x] Bundled QR-only scanner, manual fallback and asset-to-draft navigation.
- [x] Independent review, 59-test aggregate, analysis and debug APK.
- [ ] Physical-device airplane-mode QR acceptance.

## 5 — Evidence pipeline (active)

- [x] Shared filesystem/metadata/capture contracts.
- [x] JPEG preservation, checksums, thumbnails, limits/path guards and file-store review.
- [x] Additive v3 media table and capture repository implementation present.
- [x] Camera route/platform-fake tests and app-private bootstrap/recovery wiring present.
- [ ] Photo controls, thumbnails, unavailable-evidence feedback and review checks integrated.
- [ ] Legacy unresolved references preserved honestly; new-reference validation tested.
- [x] Camera lifecycle/error/retry reviewed; 9 platform-fake tests pass.
- [ ] Independent transaction/recovery/migration review accepted after fixes.
- [ ] Frozen v3 schema comparison and data-preserving migration tests pass.
- [ ] Locked dependencies/generation/formatting/analysis/entire suite pass.
- [ ] Debug APK and camera-only merged permission manifest verified.
- [ ] ADR/architecture/progress/checklist updated and coherent commit recorded.
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
