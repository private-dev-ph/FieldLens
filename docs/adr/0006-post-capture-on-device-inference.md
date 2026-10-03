# ADR 0006: Start AI inference after capture

- Status: Accepted as a project requirement; implementation pending
- Date: 2026-10-03

## Context

The inspection workflow must be reliable on a range of mobile devices, and AI is optional assistance. Live camera inference adds latency, power, performance, and lifecycle complexity before the image evidence workflow is established.

## Decision

The initial inference workflow operates on a captured image: preprocess, run ONNX inference, post-process detections, then present predictions for technician confirmation or correction. Store original model output and technician verdict as separate data.

## Alternatives considered

- Live camera inference: deferred because it increases device and interaction complexity and is not required for the core offline inspection promise.
- Replace model predictions with technician answers: rejected because auditability and model evaluation require retaining both.

## Consequences

Image capture and local file persistence precede AI work. The app needs packaged model lifecycle metadata and a review interface. Inference metadata must retain model version/hash, timing, prediction, confidence, and technician verdict independently.
