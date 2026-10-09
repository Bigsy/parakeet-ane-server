# Releases

## v0.1.0 — ParakeetCore batch library

Adds the `ParakeetCore` SwiftPM product for direct 16 kHz mono Float32 transcription
on Apple Silicon macOS 14+ with Swift 6.2. Preparation is explicit, with cache and
download policy, truthful progress, one-time warm-up and observable readiness.
A bounded FIFO queue supports cancellation and separate wait/inference deadlines;
nonpreemptible model work retains ownership until actual completion. Unload rejects
active work and is idempotent when idle. Models remain separately downloaded assets.

The standalone executable and its successful OpenAI-compatible responses remain
available. All four model IDs, decoder behavior, short-input padding, actual verbose
JSON duration, defaults and launchd commands are retained. New configurable server
limits default to one hour per request, two hours of waiting PCM and eight waiting
jobs. Audio overflow returns 413; admission/readiness failures return 503. Inference
errors are sanitized, and failed warm-up prevents startup. `--cache-root` and
`--offline` support controlled/offline preparation.

Includes a separate public consumer, clean Git-revision/app resource verification,
resource/notices-aware standalone packaging, Apple Silicon CI updates and retained
synthetic parity/timing observations. Model-backed parity was verified on Unified
int8; ordinary tests use fake models and preserve the full decoder regression suite.
Streaming sessions are a subsequent release; batch remains the initial app default.
See `bench/results/2026-10-09.md` for the scope and limits of measurements.
