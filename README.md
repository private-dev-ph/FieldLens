# FieldLens

FieldLens is an offline-first industrial inspection platform under active development. Its goal is to let a technician identify an asset, complete an inspection, collect evidence, optionally run on-device AI, sign and submit while offline, then synchronize the complete record when connectivity returns.

The local mobile foundation and demo assignment flow are implemented. Phase 3 now includes schema-driven inspection templates, validation, locally persisted drafts, and an inspection screen; its local draft behavior is verified. See the [progress tracker](docs/progress.md) for current evidence. Demo assignments are not scoped through an authenticated account. Submission, media capture, remote sync transport, cloud backend, and AI are not implemented. See the [end-to-end project plan](docs/fieldlens_end_to_end_plan.md), [architecture overview](docs/architecture.md), and [architecture decisions](docs/adr/).

## Planned components

- `apps/mobile`: Flutter and Dart technician application using Riverpod, Drift/SQLite, local media files, and an offline-first repository and synchronization design.
- `apps/console`: Next.js supervisor console.
- `supabase/`: PostgreSQL schema, migrations, Row Level Security policies, authentication, and storage configuration.
- `models/`: on-device ONNX model artifacts and metadata.
- `demo/factory-demo/`: representative industrial sites, assets, assignments, and inspection templates.
- `docs/`: architecture, decisions, security, and operational documentation.

The mobile app exists. The console, Supabase backend, and models directory remain planned. Two demo sites and the five Factory Demo assets/work orders are seeded locally by the mobile app.

## Development workflow

The mobile toolchain is pinned to Flutter 3.35.7 in `.flutter-version`. Run the repository setup script from the checkout root to install/use that SDK, resolve locked dependencies, and generate Drift code:

```sh
./scripts/setup-cloud.sh
```

In each new shell, source the environment setup after running the script:

```sh
source scripts/cloud-env.sh
```

The setup uses `/workspace/toolchains/flutter/bin` in `PATH`, `/workspace/toolchains/pub-cache` for `PUB_CACHE`, `/workspace/toolchains/config` for `XDG_CONFIG_HOME`, and local toolchain paths for analyzer state, Gradle, Android SDK, and SQLite loading. It enables CI mode and suppresses Flutter and Dart analytics. Generated Drift source is required before analysis or tests. If dependencies are available, run these from `apps/mobile`:

```sh
dart run build_runner build
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

The local demo seeds two sites and five assets/work orders without authentication or account scoping. The work-order list observes local state; starting work writes the updated status and outbox operation atomically. A technician can begin and edit a durable inspection draft using a versioned template snapshot. Answers are validated and saved locally as they change.

Formatting and analysis pass, all 38 tests pass, and `flutter build apk --debug` produces an Android debug APK. Migration and draft persistence also passed independent review. Hosted CI and physical-device end-to-end checks have not run. See the [progress tracker](docs/progress.md) for precise scope and limitations.

The setup script installs verified Flutter/JDK/Android toolchains, configures the supplied environment CA and Gradle proxy without disabling TLS, and can be rerun. Run `source scripts/cloud-env.sh` in each new shell. Production release signing is unconfigured.

## Product invariants

- The mobile UI observes local Drift/SQLite state. Normal writes update SQLite and a durable outbox in one local transaction; network availability does not decide whether ordinary inspection data can be saved.
- Stable UUIDs are generated on the device for records that may be created offline.
- Media binaries live in the device filesystem; the database stores their references and metadata.
- Synchronization is idempotent, retryable, dependency-aware, recoverable after interruption, and visible to the technician. Startup, resume, restored connectivity, and explicit requests can trigger sync.
- Mutable synchronized entities use server revisions and expected-revision checks where appropriate; meaningful conflicts are surfaced instead of silently overwritten.
- Inspection forms are schema-driven. Initial AI inference runs on a captured image, and technician judgment remains separate from the model prediction.
- Server-side authorization and organization isolation are enforced with appropriate PostgreSQL/Supabase policies and operations.

## Current status

Local demo assignments and durable inspection drafts are verified. The next milestone is offline asset identification and filesystem-backed evidence. Submission, evidence capture, remote authentication/backend, synchronization transport, AI, and later roadmap phases remain unimplemented. The [progress tracker](docs/progress.md) records phase status and the next acceptance target.
