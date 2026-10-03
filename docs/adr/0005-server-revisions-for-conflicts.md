# ADR 0005: Use server revisions for mutable-record conflicts

- Status: Accepted as a project requirement; implementation pending
- Date: 2026-10-03

## Context

Multiple devices or supervisors may edit synchronized data from stale local copies. Last-write-wins can silently erase meaningful inspection answers or review changes.

## Decision

Track a monotonically advancing server revision on mutable synchronized entities, together with update metadata where useful. The client sends the revision it expected; the server rejects stale writes as conflicts. The product surfaces meaningful conflicts for deliberate resolution.

## Alternatives considered

- Last-write-wins timestamps: rejected because clock order does not prove that an edit is safe to replace.
- Merge every field automatically: rejected because inspection and review semantics are not universally mergeable.
- Lock all records globally: rejected because it harms offline operation and still cannot ensure a device remains connected.

## Consequences

Sync APIs and persistence need revision checks and explicit conflict results. The client must preserve local conflicting data and offer a clear resolution path. Conflict behavior needs multi-client and retry coverage.
