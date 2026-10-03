# FieldLens — Offline-First Industrial Inspection Platform

## 1. Product concept

FieldLens is a serious offline-first inspection product rather than a generic mobile CRUD app.

> **FieldLens lets technicians inspect industrial assets even with no network connection, collect structured evidence, run optional AI inspection on-device, and synchronize the complete inspection record when connectivity returns.**

FieldLens has two surfaces:

| Product | Purpose |
|---|---|
| **FieldLens Mobile** | Flutter Android/iOS application used by technicians |
| **FieldLens Console** | Web dashboard used by supervisors/admins |

A typical workflow:

```text
Supervisor creates inspection assignment
            ↓
Technician's phone downloads assignment
            ↓
Technician goes offline
            ↓
Scans equipment QR / serial
            ↓
Completes inspection checklist
            ↓
Captures photos
            ↓
Optional on-device AI analyzes image
            ↓
Technician confirms/corrects AI result
            ↓
Signs/submits inspection offline
            ↓
Inspection enters "Queued for Sync"
            ↓
Connectivity returns
            ↓
Images + inspection data synchronize
            ↓
Supervisor sees submitted inspection
            ↓
Approve / Request Changes
```

The defining product requirement is that everything from scanning through submission continues to work in airplane mode.

---

## 2. Demo inspection environment

Use a believable industrial demo rather than an abstract inspection app.

### FieldLens Factory Demo

| Asset | Example inspection |
|---|---|
| Control cabinet | Wiring, corrosion, labeling, damage |
| Conveyor motor | Housing condition, temperature observation, vibration notes |
| PCB/controller | Connectors, oxidation, component damage |
| Compressor | Leaks, fittings, gauges, exterior damage |
| Network cabinet | Cable condition, labels, ports, indicators |

Every asset receives a QR code such as:

```text
FIELDLENS://ASSET/AST-CTRL-0042
```

Scanning it should immediately open the correct asset from the local database, even while offline.

---

## 3. Recommended architecture

```text
                         FIELDLENS
                            │
          ┌─────────────────┴─────────────────┐
          │                                   │
     Flutter Mobile                     Web Console
          │                              Next.js
          │                                   │
 ┌────────┴────────┐                          │
 │                 │                          │
 │ Drift / SQLite  │                          │
 │ Local Files     │                          │
 │ ONNX Runtime    │                          │
 │ Sync Engine     │                          │
 │                 │                          │
 └────────┬────────┘                          │
          │                                   │
          └──────────────┬────────────────────┘
                         │
                    Supabase
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
   PostgreSQL          Storage            Auth
       │                 │
       │          Inspection Photos
       │          Model Artifacts
       │
       └── RLS / RPC / Sync APIs
```

### Core architecture rule

The UI should not directly decide whether data is local or remote.

```text
InspectionScreen
      │
      ▼
InspectionRepository
      │
 ┌────┴────┐
 ▼         ▼
Local     Remote
Drift     Supabase
```

Repositories should act as the application's source of truth.

---

## 4. Recommended technology stack

| Layer | Technology |
|---|---|
| Mobile | Flutter / Dart |
| State management | Riverpod |
| Local database | Drift + SQLite |
| Local media | Device filesystem |
| Camera | Flutter camera integration |
| QR | Mobile QR scanner |
| AI inference | ONNX Runtime |
| Background sync | Workmanager |
| Authentication | Supabase Auth |
| Cloud database | PostgreSQL via Supabase |
| Media storage | Supabase Storage |
| Authorization | PostgreSQL Row Level Security |
| Admin dashboard | Next.js + TypeScript |
| Deployment | Vercel + Supabase |
| CI | GitHub Actions |
| Error reporting | Sentry or structured telemetry |
| Documentation | Markdown + Mermaid |

Background sync should not depend only on scheduled background work. Synchronization should also run when the application opens, resumes, regains connectivity, and when the user manually requests it.

---

## 5. Local-first data model

The phone's SQLite database should be a full application database rather than merely a cache.

| Entity | Important fields |
|---|---|
| `organizations` | id, name |
| `users` | id, org_id, role, name |
| `sites` | id, org_id, name, location |
| `assets` | id, site_id, serial, asset_tag, qr_value, asset_type |
| `inspection_templates` | id, name, revision |
| `template_items` | id, template_id, type, label, required, rules |
| `work_orders` | id, asset_id, assigned_to, template_id, status |
| `inspections` | id, work_order_id, technician_id, status, timestamps |
| `inspection_answers` | id, inspection_id, item_id, value_json |
| `attachments` | id, inspection_id, local_path, remote_path |
| `ai_runs` | id, attachment_id, model_version, result_json, inference_ms |
| `audit_events` | id, actor_id, action, entity, timestamp |
| `model_releases` | id, version, hash, artifact_path |
| `sync_outbox` | local-only queued mutations |
| `sync_metadata` | cursor, last_sync, device_id |

Generate UUIDs on-device so records created offline already have their final identifiers before reaching the server.

---

## 6. Synchronization architecture

This should be one of the technically strongest parts of FieldLens.

Avoid this model:

```text
if online:
    saveToServer()
else:
    saveLocally()
```

Instead, use a local-first write path:

```text
Every write
   ↓
SQLite transaction
   ↓
Update local domain object
   ↓
Add mutation to sync_outbox
   ↓
UI immediately updates
```

Example:

```text
User answers question

inspection_answers:
    answer = "corrosion detected"

sync_outbox:
    operation_id = UUID
    entity = inspection_answer
    entity_id = UUID
    operation = UPSERT
    payload = {...}
    created_at = ...
```

Later:

```text
Sync Engine
   ↓
Read pending operations
   ↓
Upload dependencies/media
   ↓
Push mutations
   ↓
Server validates revision
   ↓
Mark operations acknowledged
   ↓
Pull remote changes
   ↓
Merge into SQLite
```

### Idempotency

Every synchronization operation receives a unique `operation_id`.

If the phone sends an operation and loses connectivity before receiving the response, it may resend the same operation. The backend should recognize it as already processed rather than creating duplicate records.

### Visible sync statuses

Synchronization should be visible in the UI:

```text
✓ Synced

↑ 4 changes pending

⟳ Syncing

! Sync issue
```

For an offline-first application, sync state is part of the product experience.

---

## 7. Conflict handling

Every synchronized entity can include:

```text
revision: 12
updated_at: ...
updated_by: ...
```

Example conflict:

1. Device A edits revision 12.
2. Device B also edits revision 12.
3. Device A uploads with `expected_revision: 12`.
4. Server accepts it and advances the entity to revision 13.
5. Device B uploads with `expected_revision: 12`.
6. Server responds with a conflict.

Example UI:

```text
Inspection has changed on another device.

Local answer:
Loose connector

Server answer:
Damaged connector

[Keep Local]
[Use Server]
```

Not every entity needs conflict resolution. Structure workflows to reduce contention—for example, only the assigned technician edits an active inspection while supervisors review submitted inspections.

---

## 8. Inspection templates

Do not hard-code inspection forms.

Create a schema-driven inspection engine.

Example:

```json
{
  "title": "Control Cabinet Inspection",
  "items": [
    {
      "type": "boolean",
      "label": "Cabinet securely mounted",
      "required": true
    },
    {
      "type": "choice",
      "label": "Corrosion condition",
      "options": [
        "None",
        "Minor",
        "Severe"
      ]
    },
    {
      "type": "photo",
      "label": "Interior cabinet photo",
      "required": true
    },
    {
      "type": "text",
      "label": "Additional notes"
    }
  ]
}
```

Supported field types:

```text
Boolean
Pass / Fail / N/A
Single choice
Multiple choice
Numeric
Text
Photo
QR/serial
Signature
```

---

## 9. On-device AI

Do not begin with live camera inference.

Start with an image-capture workflow:

```text
Capture Image
     ↓
Resize / Normalize
     ↓
ONNX model
     ↓
Inference
     ↓
Post-processing
     ↓
Display detections
```

Example:

```text
Possible corrosion
Confidence: 87%

┌─────────────────────────────┐
│                             │
│       ┌───────────┐         │
│       │ corrosion │         │
│       └───────────┘         │
│                             │
└─────────────────────────────┘

[Confirm]
[Incorrect]
```

Store technician validation separately from model output.

```text
AI prediction:
corrosion

technician verdict:
confirmed
```

or:

```text
technician verdict:
false_positive
```

### AI metadata

Each inference should store:

```text
model_name
model_version
model_sha256
inference_time_ms
device
prediction
confidence
technician_verdict
```

The supervisor dashboard can then show model performance:

```text
FieldLens Model Performance

Confirmed detections:      84%
False positives:            9%
Rejected predictions:       7%

Median inference:         142 ms
Model:                  v1.3.2
```

---

## 10. User roles

Keep roles simple.

| Role | Capabilities |
|---|---|
| Technician | View assigned work, inspect, capture media, submit |
| Supervisor | Assign work, review inspections, request changes |
| Admin | Manage users, sites, assets and templates |

Authorization should be enforced server-side.

Conceptual policy model:

```text
Technician:
SELECT assets in own organization
SELECT assigned work_orders
UPDATE inspections assigned to self

Supervisor:
SELECT inspections in own organization
CREATE work_orders
UPDATE review status

Admin:
manage organization configuration
```

---

## 11. Mobile screens

```text
Splash / Bootstrap
        │
        ▼
Login
        │
        ▼
Dashboard
 ┌──────┼────────┐
 ▼      ▼        ▼
Assigned Drafts  Sync
Work             Status
 │
 ▼
Work Order
 │
 ▼
Scan Asset
 │
 ▼
Asset Details
 │
 ▼
Inspection
 │
 ├── Checklist
 ├── Measurements
 ├── Photos
 ├── AI Analysis
 └── Notes
 │
 ▼
Review
 │
 ▼
Signature
 │
 ▼
Submit
```

Example dashboard:

```text
FIELDLENS

● Offline

Assigned       8
In Progress    2
Pending Sync   3

Today's Inspections

FL-2041   Control Cabinet
Building A
IN PROGRESS

FL-2042   Conveyor Motor
Building C
NOT STARTED
```

---

## 12. End-to-end build plan

### Phase 1 — Foundation

Create:

- Flutter application
- Riverpod architecture
- Drift database
- Repository layer
- Database migrations
- Structured logging
- Environment configuration

**Acceptance criterion:** An asset and work order can be stored locally and rendered reactively.

### Phase 2 — Offline asset and work-order experience

Implement:

- Sites
- Assets
- Assignments
- Work-order lists
- Factory Demo seed data

Development should never depend on the remote backend being available.

### Phase 3 — Inspection engine

Build:

- Schema-driven forms
- Validation
- Boolean fields
- Choice fields
- Numeric fields
- Text fields
- Photo questions
- Draft persistence

**Acceptance criterion:** Force-closing and reopening the application must preserve the inspection.

### Phase 4 — Asset identification

Add:

- QR scanning
- Manual serial search
- Local QR resolution

**Acceptance criterion:** Asset identification works while offline.

### Phase 5 — Evidence pipeline

Add:

- Camera capture
- Thumbnails
- Metadata
- Device filesystem storage
- Drift references to media

Avoid storing image binaries directly in SQLite.

### Phase 6 — Authentication and cloud backend

Create:

- Supabase Auth
- PostgreSQL schema
- Storage buckets
- Migrations
- Row Level Security
- Organization boundaries
- Technician/supervisor permissions

### Phase 7 — Synchronization engine

Implement:

- Outbox pattern
- UUID operation IDs
- Retries
- Exponential backoff
- Media synchronization
- Remote change pulling
- User-visible sync status

Test heavily under airplane-mode conditions.

### Phase 8 — Conflict and reliability layer

Add:

- Server revisions
- Idempotent writes
- Conflict detection
- Retryable versus permanent errors
- Sync issue screen
- Recovery from app termination during synchronization

### Phase 9 — On-device AI

Implement:

- ONNX model packaging
- Image preprocessing
- Inference
- Post-processing
- Bounding-box overlays
- AI metadata storage
- Technician confirmation/correction

### Phase 10 — Supervisor Console

Build a lightweight Next.js dashboard for:

- Sites
- Assets
- Technicians
- Templates
- Assignments
- Inspection review
- Photo evidence
- AI/technician verdict comparison

### Phase 11 — Operational features

Add:

- Audit trail
- Model release metadata
- Diagnostics
- Export
- Secure logout
- Device reset
- Stale-cache cleanup

### Phase 12 — Production and portfolio layer

Add:

- CI
- Automated tests
- Release APK builds
- Schema migration validation
- Architecture documentation
- Threat model
- Demo dataset
- Screenshots/APNGs
- Architecture diagrams
- `portfolio-showcase.json`

---

## 13. Testing strategy

| Test | Scenario |
|---|---|
| Repository test | Local inspection saved correctly |
| Drift migration test | Existing database upgrades safely |
| Template test | Required fields enforce validation |
| Sync test | Offline mutation uploads later |
| Idempotency test | Same operation sent twice |
| Conflict test | Two revisions collide |
| Media test | Metadata succeeds but image upload fails |
| Recovery test | Application closes during synchronization |
| Auth test | Session expires while device is offline |
| Widget test | Template fields render correctly |
| AI preprocessing test | Image tensor dimensions/normalization |
| AI postprocessing test | Bounding boxes/NMS correctly mapped |
| Integration test | Entire offline inspection → online sync |
| Security test | Technician cannot access another organization |

The most important end-to-end test:

```text
Download assignments
↓
Disable network
↓
Complete inspection
↓
Capture evidence
↓
Submit
↓
Restart app
↓
Inspection still exists
↓
Restore network
↓
Synchronize
↓
Server contains identical inspection
```

This test expresses the core promise of the entire project.

---

## 14. Supervisor dashboard

Keep the dashboard focused.

Example:

```text
FieldLens Console

Assets        42
Open Work     12
Submitted      6
Issues         3

Recent Inspections
────────────────────────────────────────────

FL-2041   Control Cabinet   Daniel M.   Review
FL-2040   Compressor       Juan D.     Approved
FL-2039   Conveyor Motor   Maria S.    Changes
```

Inspection detail:

```text
Control Cabinet — CC-0042

Technician: Daniel
Site: Factory A
Status: Submitted

Checklist
────────────────────────
✓ Cabinet mounted
✓ Wiring secured
! Corrosion detected

Evidence
[photo] [photo] [photo]

AI Result
Possible corrosion — 87%

Technician:
Confirmed

[Approve Inspection]
[Request Changes]
```

---

## 15. Features to leave out initially

Do not build these in the first release:

- GPS tracking
- Live video inference
- Chat
- Billing/subscriptions
- Drag-and-drop visual template designer
- Real-time collaborative editing
- Route optimization
- IoT sensor ingestion
- Predictive maintenance
- Generative-AI inspection reports

The first release should stay focused on:

> **Offline-first mobile architecture + reliable synchronization + industrial inspection + edge AI.**

---

## 16. Recommended repository structure

```text
fieldlens/
│
├── apps/
│   ├── mobile/
│   │   ├── lib/
│   │   │   ├── core/
│   │   │   ├── database/
│   │   │   ├── sync/
│   │   │   ├── features/
│   │   │   │   ├── auth/
│   │   │   │   ├── assets/
│   │   │   │   ├── work_orders/
│   │   │   │   ├── inspections/
│   │   │   │   ├── camera/
│   │   │   │   └── inference/
│   │   │   └── main.dart
│   │   └── test/
│   │
│   └── console/
│       ├── app/
│       ├── components/
│       └── lib/
│
├── supabase/
│   ├── migrations/
│   ├── functions/
│   └── seed.sql
│
├── models/
│   ├── manifest.json
│   └── README.md
│
├── docs/
│   ├── architecture.md
│   ├── offline-sync.md
│   ├── database.md
│   ├── security.md
│   ├── ai-inference.md
│   └── adr/
│
├── demo/
│   └── factory-demo/
│
├── .github/
│   └── workflows/
│
├── portfolio-showcase.json
└── README.md
```

### Suggested Architecture Decision Records

```text
ADR-001 Use Drift as local source of truth
ADR-002 Use operation outbox for synchronization
ADR-003 Store media outside SQLite
ADR-004 Use client-generated UUIDs
ADR-005 Use server revisions for conflicts
ADR-006 Run inference after capture rather than live
```

---

## 17. Portfolio presentation

Do not present the project as:

> "A Flutter inspection app using Supabase."

Present it as:

> **An offline-first industrial inspection platform designed for technicians working in unreliable network environments, combining schema-driven inspections, resilient bidirectional synchronization, photographic evidence and on-device AI inference.**

The ideal demo should show:

```text
1. Scan asset

2. Complete inspection in airplane mode

3. Run AI on captured image

4. Reconnect and watch the inspection synchronize
```

Show the pending state:

```text
3 changes pending
```

Then reconnect:

```text
Syncing...
✓ Synced
```

That sequence should be the centerpiece of the project demo.

---

## 18. What the finished project proves

| Capability | Evidence |
|---|---|
| Flutter | Entire production-shaped mobile application |
| Dart | Domain and application architecture |
| SQLite | Real local relational database |
| SQL/PostgreSQL | Cloud relational schema |
| Distributed systems | Offline synchronization |
| Reliability | Retries, idempotency, conflicts |
| Mobile engineering | Camera, lifecycle, filesystem, background tasks |
| Security | Authentication + RLS |
| Cloud | Database + object storage + deployment |
| Edge AI | ONNX inference on-device |
| MLOps | Model versions and inference metadata |
| Full-stack | Mobile + cloud + web console |
| Testing | Synchronization and offline E2E tests |

## Final project identity

FieldLens should demonstrate more than mobile development.

It should show that you can design and ship a reliable system spanning:

- mobile
- offline storage
- synchronization
- cloud infrastructure
- authorization
- computer vision
- model lifecycle
- observability
- testing
- web administration

The model should be only one component of the system.

The strongest engineering story is the infrastructure surrounding it.
