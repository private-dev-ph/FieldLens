# ADR 0003: Keep media files outside SQLite

- Status: Accepted as a project requirement; implementation pending
- Date: 2026-10-03

## Context

Inspection photos and related evidence must be captured offline, retained locally, and uploaded later. Storing large binary data in the relational mobile database would complicate database size, backup, and transfer behavior.

## Decision

Write media binaries to the device filesystem. Store references, metadata, and synchronization state in Drift. Upload files to remote object storage before mutations that depend on their remote references.

## Alternatives considered

- Store binaries as SQLite blobs: rejected because media should have independent file lifecycle and upload handling.
- Upload directly from the camera to cloud storage: rejected because capture must work offline.

## Consequences

The implementation must manage file/database consistency across interruption, protect local files, retain media until it is safe to remove, and represent partial upload failures. Tests should cover missing files, retries, and interrupted uploads.
