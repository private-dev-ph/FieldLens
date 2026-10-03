# ADR 0003: Keep media files outside SQLite

- Status: Accepted; implemented in Phase 5
- Date: 2026-10-03

## Context

Inspection photos and related evidence must be captured offline, retained locally, and uploaded later. The filesystem and SQLite cannot participate in one transaction. A process may stop between writing a file and committing its metadata, or after metadata changes while one of the files is incomplete. Storing large binary data in the relational mobile database would also complicate database size, backup, and transfer behavior.

## Decision

Store original photo and thumbnail bytes in the app-private filesystem, addressed by client-generated media UUID. Drift stores media metadata, dimensions, checksums, capture-intent/recovery state, and references from answers and queued snapshots. Schema version 3 is additive and introduces `InspectionMedia` metadata and capture-intent rows without changing an existing draft's immutable template snapshot. The Factory Demo template advances to revision 2 with an optional photo field for newly created drafts; existing drafts retain their prior template snapshot.

Capture writes and flushes temporary files, then atomically renames them to final UUID-addressed JPEG and 256-pixel thumbnail paths. The database transaction that marks media ready also updates the photo answer and inserts a full replayable inspection/outbox snapshot. Startup recovery completes interrupted work when a valid original exists, repairs a missing thumbnail when possible, and surfaces missing or corrupt evidence for recovery. Files referenced by queued snapshots are retained; cleanup must not eagerly delete them.

No remote upload or server object-storage behavior is part of this phase. Authentication, synchronization transport, inspection submission, and signatures remain separate work.

## Alternatives considered

- Store photo binaries as SQLite blobs: rejected because media should have an independent file lifecycle and upload path, while large blobs would inflate the local database.
- Write directly to final file names: rejected because a crash could leave a truncated file that appears complete.
- Commit an answer before files are durable: rejected because local state could refer to evidence that was never fully written.
- Delete local media as soon as a draft changes: rejected because queued snapshots may still reference the original UUID-addressed media.
- Upload directly from the camera to cloud storage: rejected because capture must work offline.

## Consequences

The capture workflow needs explicit database/file recovery states, UUID-only paths under app-owned storage, integrity metadata, and safe temp-file rename behavior. Finalization must coordinate media readiness, the photo answer, and its outbox snapshot in one SQLite transaction after files are durable. Transient filesystem failures leave durable intents and ready records retryable; invalid input and confirmed missing/corrupt evidence have explicit terminal states. Startup recovery must retain enough metadata to distinguish complete originals, repairable thumbnails, and missing/corrupt evidence. Cleanup must account for outstanding snapshot references. The v3 `InspectionMedia` migration, filesystem store, capture screen, and `MediaRepository` operations for beginning, completing, cancelling, and recovering intents are now present. Recovery is wired into app-private startup bootstrap. Camera capture is connected to draft UI. Review verifies ready ownership, lengths and checksums; unavailable references can be removed without deleting retained evidence. Aggregate verification passes 102 tests, formatting, analysis, schema comparison and Android debug packaging. Native camera tests use a fake platform, and physical-device acceptance has not run.
