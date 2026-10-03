# ADR 0001: Drift is the mobile local source of truth

- Status: Accepted; implemented for local assignments and inspection drafts
- Date: 2026-10-03

## Context

Technicians must complete and submit inspections while disconnected. A network-dependent UI or remote-first persistence path would make ordinary work unavailable in airplane mode and make process recovery unreliable.

## Decision

Use Drift over SQLite as the full local application database on mobile. Repositories expose local state to the UI, and normal writes commit locally before synchronization. The UI does not choose between local and remote storage based on connectivity.

## Alternatives considered

- Remote-first writes: rejected because a network outage would block inspection work.
- SQLite as a disposable cache: rejected because local records and drafts must survive app restarts and remain useful offline.
- Direct database access from widgets: rejected because it couples presentation to persistence and synchronization behavior.

## Consequences

The mobile app needs a schema, migrations, reactive queries, repository boundaries, and local data lifecycle. Sync must reconcile server changes into local state without making the network the UI's source of truth.
