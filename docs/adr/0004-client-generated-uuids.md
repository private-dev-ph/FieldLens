# ADR 0004: Generate stable record identifiers on the device

- Status: Accepted; implemented for drafts, answers, and queued operations
- Date: 2026-10-03

## Context

Assets, work orders, inspection answers, and attachments can be created or changed before a device has network access. Requiring a server-generated identifier would block offline creation or force identity remapping later.

## Decision

Generate UUIDs on-device for records that may originate offline and preserve those identifiers through synchronization. Outbox operations also receive stable UUIDs for idempotency.

## Alternatives considered

- Allocate IDs only on the server: rejected because the server may be unreachable at creation time.
- Replace temporary local IDs after upload: rejected because remapping breaks local references and complicates retries.

## Consequences

Database keys and remote APIs must accept client UUIDs. The server must validate uniqueness and operation idempotency rather than assuming IDs were allocated centrally.
