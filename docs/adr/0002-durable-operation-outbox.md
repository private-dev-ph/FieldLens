# ADR 0002: Use a durable operation outbox for synchronization

- Status: Accepted; local outbox implemented, synchronization transport pending
- Date: 2026-10-03

## Context

Local writes can succeed while the network is unavailable, and a process can stop during any request. Reconstructing intended changes from current rows alone makes retry, idempotency, ordering, and recovery difficult.

## Decision

Write a durable outbox operation in the same local database transaction as each eligible local mutation. Give every operation a client-generated UUID. Synchronization processes pending operations with dependency ordering, idempotent server handling, retry/backoff, error classification, and acknowledgement state.

Use a local SQLite `AUTOINCREMENT` sequence to order operations. Keep the operation UUID unique as the transport identity; the local sequence is never a server record identifier. Wall-clock timestamps can tie or regress, so they cannot define replay order. Deleting acknowledged operations must not reuse sequence numbers. Draft snapshots retain answer UUIDs and immutable template provenance.

Schema version 2 preserves version 1 outbox rows using Drift's transactional table migration, copying their SQLite row order into the new sequence. Migration tests cover unchanged payloads, equal timestamps, and deletion followed by insertion.

## Alternatives considered

- Send each mutation directly to the server: rejected because offline writes and interrupted requests are not durable.
- Infer changes by comparing full local and remote snapshots: rejected because it obscures operation identity, ordering, and retry semantics.
- Depend solely on scheduled background jobs: rejected because platform scheduling is not guaranteed and foreground triggers are also required.

## Consequences

The outbox schema and server operation contract must be designed together. Sync state is durable product state and must be visible and recoverable. The client should trigger sync on startup, resume, restored connectivity, and explicit request, with background work as an additional mechanism.
