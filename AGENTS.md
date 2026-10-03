# FieldLens engineering workflow

Read `README.md`, `docs/progress.md`, `docs/fieldlens_end_to_end_plan.md`, relevant ADRs, Git status, and recent history before implementation. Confirm progress against code and tests. Preserve unrelated user changes. Use the existing isolated checkout; create a worktree only when explicitly requested.

Retain architecture, shared contracts, synchronization semantics, security decisions, integration, and acceptance with the lead orchestrator. Delegate bounded implementation and independent review after interfaces are established. Use GPT-6.1 Sol for orchestration and GPT-6 Luna with High reasoning for bounded tasks when explicit model selection is available; otherwise preserve that reasoning/capability hierarchy. Give agents file ownership, constraints, dependencies, and required verification. Avoid concurrent edits to central files.

Follow the project plan's dependency order. Complete a coherent milestone, review it independently, verify it, update progress, and advance when prerequisites permit. Report concrete blockers and unrun checks accurately. Use natural commit and branch names describing engineering outcomes.

## Architectural requirements

- Drift/SQLite is authoritative for the mobile UI. Observe local repository streams; never choose persistence based on network availability.
- Commit normal local mutations and durable outbox operations in the same transaction. Retain UUID operation identities and monotonic local replay ordering.
- Generate stable UUIDs on-device. Preserve answer IDs and immutable template snapshots in queued inspection data.
- Store media on the filesystem with database references, never image binaries in SQLite.
- Synchronization must preserve dependencies, idempotency, revision conflicts, retries, recovery, and visible state. No queued operation may be acknowledged without server confirmation.
- Enforce organization and role boundaries server-side. Demo data is not authenticated production data.
- Render inspection forms from schemas. Run inference after capture; retain original predictions separately from technician verdicts.
- Do not add the out-of-scope features listed in the project plan.
- Never commit credentials, raw inspection evidence in diagnostics, or development signing keys as production release keys.

## Verification

In this cloud workspace run `bash scripts/setup-cloud.sh`, then `source scripts/cloud-env.sh` in each new shell. From `apps/mobile`, generate Drift code with `dart run build_runner build`, check formatting, run `flutter analyze`, and run meaningful targeted tests followed by `flutter test`. Run `flutter build apk --debug` for Android packaging. Check frozen schemas and data-preserving migrations when changing the database. Keep hosted CI, physical-device tests, and local checks distinct in reports.
