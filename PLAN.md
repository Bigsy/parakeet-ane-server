# ParakeetCore library and standalone server implementation plan

Updated: 9 October 2026. Status: M0–M3 implemented; batch release validation complete.
Streaming spike measured; session implementation follows the batch release.

Implementation evidence (9 October 2026): baseline 31 tests and release build passed;
core/HTTP suites, public consumer, clean Git-revision consumer and macOS app resource
assembly passed. Unified batch outputs match the frozen baseline and real HTTP on
seven synthetic fixtures. The isolated 25-second repeat shows no material batch
regression. See `bench/results/2026-10-09.md` and retained raw observations. First
assembled-server preparation took 24.40 seconds on this host. The streaming spike
covers 630 observations across three chunk sizes; the long fixture adds a final
period compared with batch. Model weights remain outside source control.

Release/streaming milestones remain unchecked until their respective tag/session
gates are completed. Extended idle/energy and broader accuracy benchmarks remain
opt-in; batch is the conservative first consumer default.

Repository: `https://github.com/Bigsy/parakeet-ane-server`.
Starting revision checked after rebasing onto `origin/main`:
`d4e9a8ab35f71259776c8e9c282a42796082a1f5` (9 October 2026).

This document is a complete handoff for implementing the work in this repository.
It does not require the earlier conversation or the whispr-lite plan. Recheck the
working tree and dependencies when starting; preserve any changes made since this
document was written.

## 1. Objective and agreed scope

Make this repository provide two products backed by the same ASR implementation:

1. **`ParakeetCore`**, an importable Swift library for batch and streaming transcription
   of microphone samples inside another macOS application's process.
2. **`parakeet-ane-server`**, the existing independently buildable, installable HTTP
   server, retaining its CLI, OpenAI-compatible API and current decoding behavior.

The first consumer is **whispr-lite**, a native menu-bar dictation app in the sibling
repository. It holds a hotkey to record, transcribes locally, sends the final transcript
to an existing llama-server for cleanup and inserts the cleaned result at the cursor.
It also pauses media during recording. Its client-specific work stays in that repository.

**Platform: macOS on Apple Silicon only.** Preserve the current macOS 14 deployment
target where the pinned dependencies permit it. Do not add Windows/Linux/Intel support,
cross-platform layers or mobile targets because FluidAudio happens to support them.

The app must consume the core through a versioned Swift Package Manager dependency.
Its repository must not contain a copied or vendored version of this project's ASR source.
Keep the repository name and standalone executable name; a separate new repository or
central package-registry upload is unnecessary.

### Expected result

```text
                       parakeet-ane-server repository
                                  |
                    importable ParakeetCore library
                         /                    \
    existing HTTP server / CLI          whispr-lite application
    uploads -> decode -> core           microphone PCM -> core
    same API for OpenWhispr              direct batch / streaming calls
```

The app path bypasses HTTP upload, WAV construction, temporary audio files and
server-side decoding. This removes surrounding work; it does not make model inference
itself faster or guarantee a particular release-to-text latency.

### Out of scope

Do not add hotkeys, microphone permission UI, audio device selection, pre-roll capture,
media controls, clipboard/Accessibility insertion, Gemma cleanup prompts or llama.cpp
management to `ParakeetCore`. Those are whispr-lite responsibilities. An HTTP streaming
endpoint, cloud service, authentication redesign, XCFramework distribution and model
changes are also outside the first library release.

## 2. Starting state and constraints

| File / component | Current behavior | Work needed |
|---|---|---|
| `Package.swift` | Exports only the server executable; ASR, decoder and HTTP code share the `ParakeetANE` target. | Export a core library and separate target dependencies. |
| `SpeechModel.swift` | Public `SpeechModel` accepts `[Float]`; `ModelChoice.load()` loads Unified, Ultra, v2 or v3. | Move inference/model selection into the core; add configurable preparation lifecycle. |
| `TranscriptionService.swift` | Serial task chain; empty input returns empty text; clips below one second are padded. | Retain these semantics; add bounded admission and explicit cancellation ownership. |
| `TranscriptionService.minimumSamples` | Reads `AudioDecoder.sampleRate`. | Move the 16 kHz contract to the core; the core cannot depend on file decoding. |
| `warmUp()` | Logs a failed warm-up and returns without throwing. | Expose failure/readiness to library callers; define server startup behavior explicitly. |
| `AudioDecoder.swift`, `AudioFormat.swift`, `WebMOpus.swift` | Container sniffing, native decode, optimized WebM/Opus and ffmpeg fallback. | Keep in the server adapter; preserve its existing tuning and tests. |
| `Server.swift`, `OpenAITypes.swift` | Hummingbird routes, multipart parsing and API responses. | Wrap the new core without changing successful response contracts. |
| Server executable | Loads a model, warms it, then runs HTTP service. | Keep a thin independently usable entry point. |
| FluidAudio | Already implements Unified batch and streaming ASR. | Wrap existing managers; do not rewrite inference. |

The checked dependency pins are FluidAudio `0.17.7`, Hummingbird `2.27.0`, MultipartKit
`4.7.1`, ArgumentParser `1.8.2` and resolved swift-log `1.16.1`. FluidAudio resolves to
`503b4bd1bbf7220882de39fe8ae6716aae4132da`.

The root manifest and pinned Hummingbird/swift-log manifests require **Swift 6.2**.
The latest commit already corrected this requirement. Preserve it and verify the clean
dependency graph; do not downgrade or upgrade dependencies simply to make extraction easier.

The starting commit also already adds MIT licensing and third-party notices, Apple
Silicon macOS CI, concurrently drained ffmpeg stderr, WebM metadata/padding/overflow
guards, their regression tests and more robust LaunchAgent installation paths. Keep
these changes and tests intact. They are completed baseline work, not tasks to redo.

The existing queue is useful but not sufficient for cancellation: it creates an
unstructured job task and awaits it, without propagating caller cancellation or removing
cancelled queued jobs. Swift actors are reentrant across `await`; merely moving more
functions into an actor will not prevent model/session operations from interleaving.

### Standalone behavior to preserve

- `GET /health` returns the existing readiness success once model preparation is complete.
- `GET /v1/models` lists the selected model with its existing ID and response shape.
- `POST /v1/audio/transcriptions` accepts multipart `file`, with `response_format`
  values `json`, `text` and `verbose_json`. Other currently accepted fields retain their
  existing behavior; this refactor does not introduce prompt/language support.
- Existing model variants, defaults, host/port flags, ffmpeg fallback and transcript-log
  opt-in remain usable. Keep loopback port `11435` and the executable name.
- Preserve the difference between actual input duration and padding supplied to ASR.
  `verbose_json` must continue reporting actual audio duration and existing segment behavior.
- Existing valid uploaded formats and optimized sample-exact WebM decoding still work.
- `make build`, `make test`, `make install`, `make restart`, `make logs`, `make uninstall`
  and the existing LaunchAgent label remain available.
- Unit/HTTP tests ordinarily use stub models, without downloading speech models.

Preserving the server does not require retaining defects. Admission limits and readiness
failures may gain explicit errors, but document and test any observable behavior change
separately from moving files. Do not change valid JSON responses incidentally.

## 3. First actions when implementation starts

- [x] Read this file, the current README, `Package.swift`, `Package.resolved` and any
  applicable `AGENTS.md`; inspect `git status` before editing.
- [x] Capture the starting commit, toolchain, dependency resolutions and uncommitted
  work. This plan targets the fresh checkout, not a different temporary review copy.
- [x] Resolve/build/test with an appropriate Apple Silicon macOS toolchain. Establish
  which failures are baseline environment/dependency issues before refactoring.
- [x] Freeze HTTP response fixtures, decoder/sample-count behavior and model IDs.
- [x] Save a small synthetic speech corpus and baseline batch outputs on the current
  model. Keep optional model inference benchmarks separate from ordinary tests.
- [ ] Record release-build timing for direct existing `TranscriptionService` calls and
  HTTP uploads. Use identical PCM/model state for comparisons rather than comparing
  unrelated compressed recordings or cold/warm runs.

Useful initial commands:

```sh
git status --short
swift --version
swift package resolve
swift test
swift build -c release
.build/release/parakeet-ane-server --help
```

Do not run `make install` merely to establish the baseline: it changes the running
user service. Model-backed tests need their explicit opt-in preparation step.

## 4. Target package structure

Keep `ParakeetANE` as the internal server adapter module initially to reduce churn:

```text
Package.swift
Sources/
  ParakeetCore/
    PCM16kMono.swift          validated sample contract and limits
    ModelChoice.swift        existing model selection / stable IDs
    SpeechModel.swift        existing inference wrappers / internal test seam
    ParakeetEngine.swift     preparation, batch inference and model ownership
    ModelPreparation.swift   cache/download/load/warm-up progress and readiness
    OperationQueue.swift     bounded FIFO, cancellation and exclusive ownership
    TranscriptionResult.swift
    ParakeetError.swift
    StreamingSession.swift   later milestone
  ParakeetANE/
    Server.swift
    OpenAITypes.swift
    AudioDecoder.swift
    AudioFormat.swift
    WebMOpus.swift
  parakeet-ane-server/
    ParakeetANEServer.swift
Tests/
  ParakeetCoreTests/
  ParakeetANETests/           existing decoder and HTTP tests
Examples/CoreConsumer/      separate consumer package using only the public product
bench/                      optional synthetic fixtures and reproducible reports
launchd/                    existing standalone-service setup
```

Names are the proposed design, not already implemented APIs. Keep file count proportional
to actual responsibilities; combining small value types is fine.

### Product and dependency rules

- [x] Export `.library(name: "ParakeetCore", targets: ["ParakeetCore"])` alongside the
  unchanged executable product. Leave library linkage automatic initially.
- [x] Let the core depend on FluidAudio and explicitly declared swift-log if retained.
  Use the already resolved compatible logging version instead of relying on Hummingbird
  to make a transitive `Logging` import available.
- [x] Keep Hummingbird, MultipartKit, file/container decoding and ffmpeg execution out of
  the core target's dependency closure. FluidAudio may bring its own unavoidable resources
  or binaries; distinguish those from this repository's HTTP dependencies.
- [x] Let the server adapter depend on `ParakeetCore` plus its existing transport/decoder
  dependencies. Its decoder may still need FluidAudio's audio converter directly.
- [x] Keep ArgumentParser and the `ExpressibleByArgument` adaptation in the executable.
- [x] Import the core explicitly from server/tests where needed. Do not expose unrelated
  server implementation as an additional public library merely to avoid moving imports.
- [x] Ordinary core tests have no Hummingbird/MultipartKit requirement. Keep stub injection
  at the model/engine boundary so concurrency tests do not invoke CoreML.

Package resolution can still fetch dependencies declared at the root manifest even when
the consumer builds only the library product. The first gate is that server targets are
not compiled/linked into the core consumer. Do not promise that declaring two products
automatically eliminates every server dependency checkout. A separate core manifest/repo
is an optimization to consider only if measured resolution cost justifies it.

**Exit:** server and tests build using the extracted core; a separate consumer can
`import ParakeetCore`; inference has not been rewritten or changed.

## 5. Public batch API and data contract

Expose a small app-facing API using Swift/Foundation values. Hide FluidAudio manager
types, Hummingbird requests, multipart forms, mutable audio buffers and CLI configuration.
No public function takes a file upload or requires a network listener to transcribe PCM.

Suggested contract, to finalize with the consumer example:

```text
ParakeetEngine(configuration: EngineConfiguration)
  prepare(progress: @Sendable (PreparationProgress) -> Void) async throws
  transcribe(PCM16kMono) async throws -> TranscriptionResult
  startStreaming() async throws -> StreamingSession       [streaming milestone]
  unload() async throws
  state / capabilities                                  [read-only snapshots]

PCM16kMono(samples: [Float]) throws
TranscriptionResult: text, modelID, actualAudioDuration, content-free timing fields
EngineConfiguration: model, mode, cache/download policy, queue and audio limits
PreparationProgress: stage and available per-stage progress
ParakeetError: typed actionable failure categories
```

### PCM behavior

- [x] State precisely: **16,000 samples/second, mono Float32 samples**, with a documented
  normalized amplitude convention. There is no WAV header and no compression.
- [x] Validate nonfinite samples, size/duration limits and counts safely. Never silently
  reinterpret 48 kHz/stereo input as 16 kHz/mono. The caller handles capture and conversion.
- [x] Preserve empty input as an empty successful transcript without running inference.
- [x] Preserve short-speech handling: pad nonempty clips below one second as required
  by the current batch model. Do not report padded duration as microphone duration.
- [x] Preserve current whitespace normalization and model IDs. Changes to punctuation,
  normalization or silence detection need separate parity evidence.
- [x] Avoid unnecessary whole-buffer copies. Use immutable owned value buffers and
  bounded lifetimes; do not export unsafe pointer lifetimes to the app.
- [x] Make the sample-rate constant a core-owned value; remove its dependency on
  `AudioDecoder.sampleRate`. Let the server decoder use the core contract.

### Errors, readiness and diagnostics

- [x] Distinguish not-ready, preparation/download failure, invalid audio, limit exceeded,
  busy/queue-full, unsupported mode/model, inference failure and cancellation.
- [x] Keep public result/configuration/progress/error data compatible with Swift 6 strict
  concurrency. Use `Sendable` values and avoid public unchecked-sendability escapes.
- [x] Return queue, inference and total timing separately using a monotonic clock.
  Timing must not include transcript text or a hidden transcript log.
- [x] Logging is optional/configurable; the library must not take over global logging
  bootstrap, open UI or start a daemon. Readiness is never inferred from an HTTP probe.
- [x] Keep direct transcribe output as raw ASR text. LLM cleanup remains in the app.

**Exit:** the public product can prepare/transcribe/unload with actionable errors,
preserves baseline outputs, and has no HTTP/file-decoder dependency in its execution path.

## 6. Model preparation and resource ownership

- [x] Move load/startup warm-up responsibility into the core so server and app use the
  same lifecycle. Preparing twice concurrently must join or reject deterministically;
  it must not load two managers accidentally.
- [x] Expose loading stages: checking cache, downloading if allowed, loading/compiling,
  warming up and ready. Report true progress where FluidAudio supplies it; do not invent
  a misleading continuous percentage for phases that expose none.
- [x] Preserve the existing default FluidAudio cache under
  `~/Library/Application Support/FluidAudio/Models`, allowing the app to reuse downloads.
  Offer an explicit cache root for controlled applications and tests.
- [x] Support a clear download policy: allow first-use download, or require an existing
  cache and return an actionable error when missing. Importing the module or creating
  an engine must not silently begin downloading.
- [x] Inspect the pinned managers' actual cache/load APIs before promising custom paths.
  If a requested option cannot be implemented consistently, reject it explicitly or
  document a supported-model limitation; do not fall back to another path silently.
- [x] Keep Unified batch as the default and preserve Ultra/v2/v3 in server mode. Initially
  expose streaming capability only for verified Unified support.
- [x] Preserve established compute-unit/precision behavior. Verify Unified int8 stays on
  CPU + Neural Engine where required; do not route it to the GPU merely for uniformity.
- [x] Warm once on successful preparation. A failure must prevent a false ready state;
  the server must fail startup or explicitly expose a failed readiness state.
- [x] Provide bounded, idempotent unload/shutdown behavior that respects active jobs.
  Document that releasing objects does not guarantee immediate OS memory reclamation.
- [x] Coordinate cache creation/recovery if another process uses the same model directory.
  Reuse upstream completeness/recovery facilities; do not delete a shared cache while a
  concurrent application is loading it.
- [x] Keep downloads and model files separate from package source releases. Record model
  identities/variants used in parity tests; retain upstream license attribution.
- [x] Do not introduce periodic keep-warm inference. The existing measurements found
  no benefit worth the idle power cost; retain the one-time preparation warm-up.

One engine owns one selected mode/model at a time by default. Batch and streaming may
require different encoder bundles. Measure switching and dual residency explicitly;
sharing a disk cache does not mean model memory or prepared execution is shared.

**Exit:** preparation is observable, cancellable where supported and repeatable;
cached/offline operation works; model failures cannot produce false readiness.

## 7. Bounded operation queue and cancellation

Do this before declaring the library ready for the app. A caller cancelling a dictation
must not leave needless queued model work or let results escape into a later session.

- [x] Replace or extend the existing task chain with explicit FIFO ownership, request
  IDs, bounded queued work and one active model operation. Make capacity configurable;
  an initial library queue capacity of eight is a starting point, not a throughput promise.
- [x] Check cancellation before validation/admission, after registration, before model
  invocation and before returning a result. Test cancellation arriving between those steps.
- [x] Propagate cancellation using a cancellation handler and race-safe request lookup.
  Remove cancelled queued jobs promptly, resume their waiter once and release retained audio.
- [x] When inference has started, request cancellation if the upstream operation supports
  it. Never claim that cancelling a Swift task immediately aborts a CoreML/ANE prediction.
- [x] Hold the model permit until the actual running inference finishes or is safely
  aborted. A caller may stop waiting earlier, but the next job must not start on the same
  mutable manager while the cancelled one is still running.
- [x] Discard cancelled/obsolete results; clean up resources even when the result is
  discarded. Late completions may release their own permit, but cannot affect a later job.
- [x] Do not let an error poison the queue. All success/failure/cancellation paths must
  settle their waiter and permit exactly once.
- [x] Validate queued duration/sample totals as well as job count. Otherwise a bounded
  count of huge buffers can still consume unbounded practical memory.
- [x] Separate queue-wait deadlines from inference deadlines. A deadline signals a
  failure to the caller; it must not imply that the underlying model operation has stopped.
- [x] Coordinate preparation, transcribe, streaming, mode changes and unload through the
  same ownership rules. Initially reject conflicting streaming/unload requests with a
  typed busy error rather than inventing complex preemption behavior.
- [x] Keep the server's valid workload usable. Configure its limits deliberately rather
  than inheriting the app's 120-second ceiling accidentally; document new queue-full/
  limit responses and map them to explicit HTTP errors such as 503/413 where appropriate.
- [x] Preserve the existing 100 MiB upload cap. Any new decoded-duration cap must be
  configurable, separately documented and verified against accepted standalone workloads.

**Exit:** race tests show at most one operation touching a manager; cancelled queued
work never runs; nonpreemptible cancelled work keeps ownership until safe cleanup;
subsequent work always proceeds after errors.

## 8. Streaming library milestone

Build this after the batch library and standalone compatibility are dependable. No
WebSocket is needed for whispr-lite: it calls the session object inside its own process.

### 8.1 — Verify the existing upstream behavior

The pinned Unified manager supplies `appendAudio(AVAudioPCMBuffer)`,
`processBufferedAudio()`, `getPartialTranscript()`, `finish()`, `reset()` and `cleanup()`.
The default context has about **2.08 seconds of theoretical partial-transcript lag** and
re-encodes a rolling audio window. Measure final flush cost, not just partial latency.

- [ ] Benchmark the pinned streaming manager on the same synthetic audio as batch.
  Check residual work at release, accuracy/disagreement, short utterances and long pauses.
- [ ] Verify the appropriate streaming encoder files and compute-unit/precision settings.
  The streaming encoder can be distinct from the batch one even when decoder files overlap.
- [ ] Inspect `appendAudio`'s conversion path before wrapping it. Construct a correctly
  formatted 16 kHz mono buffer, avoid double resampling and measure copying/conversion cost.
  If an upstream raw-sample overload would materially help, propose a narrow upstream
  change; do not fork or rewrite FluidAudio preemptively.
- [ ] Check model minimum-input/flush behavior independently of batch padding. Do not
  blindly pad each streaming chunk to one second or alter its sample timeline.

### 8.2 — Session API and ownership

Proposed public session contract:

```text
StreamingSession
  id / generation
  append(PCM16kMono, startingAt: sampleOffset) async throws
  updates: AsyncThrowingStream<TranscriptUpdate, Error>
  finish() async throws -> TranscriptionResult
  cancel() async

TranscriptUpdate
  sessionID, revision, fullTranscript, processedAudioPosition
```

- [ ] Give each session exclusive ownership of its mutable manager. An app can have one
  recording session; starting another while one is active returns a clear busy error.
- [ ] Accept PCM chunks with explicit contiguous sample offsets. Reject missing, repeated,
  overlapping or out-of-order chunks before mutating the model timeline.
- [ ] Use one ordered processing queue for append/process/finish/cancel; actor reentrancy
  must not allow finish/reset to race an awaited inference step.
- [ ] Document that append may suspend for backpressure and is unsuitable for a real-time
  microphone callback. The app sends copied/owned buffers from its capture worker.
- [ ] Bound frame/chunk size, queued samples and total session duration. Initial app-oriented
  session limit is 120 seconds; the library exposes configuration instead of owning the
  app's hotkey safety timer. Overflow produces an error, never silent sample loss.
- [ ] Use small transport-independent input chunks as the caller prefers, initially
  20–40 ms in the app. These do not change the model's much larger inference windows.
- [ ] Process buffered audio as complete windows become available. Coalesce overlapping
  processing requests and do not run inference once per tiny chunk unnecessarily.
- [ ] Emit revisioned full partial-transcript snapshots. Use a bounded newest-value
  buffer so a slow UI/prefill consumer does not accumulate an unbounded transcript history.
  Partial updates are observations, not committed text for insertion.
- [ ] Make `finish()` the authoritative final-result operation: drain accepted audio in
  order, flush the residual window once, return one result and reset/release ownership.
- [ ] Define repeat-finish behavior consistently (same cached final result or typed
  already-finished error). It must never re-run inference or deliver an unrelated session.
- [ ] Make cancel idempotent. End the update stream, discard provisional results and reset
  once running model work settles safely. No partial callback may leak into the next session.
- [ ] Define the race between finish and cancel. If cancel wins before successful final
  completion, suppress the final result; a published result cannot be retroactively undone.
- [ ] Provide explicit shutdown for abandoned sessions. Stream-consumer termination alone
  is not sufficient evidence that the caller abandoned the recording; support observation
  cancellation separately from session cancellation.
- [ ] Preserve context across silent pauses. Do not split dictation into independent VAD
  utterances, which can lose short phrases and context.

### 8.3 — Memory, fallback and final text

- [ ] Measure batch-only, streaming-only and dual-manager residency. Default to one selected
  mode rather than always retaining two full encoder stacks. Offer dual residency only
  if measured fallback latency and memory cost justify it.
- [ ] Document whether changing modes requires unload/load/warm-up. Do not promise an
  immediate batch fallback from a streaming-only prepared engine.
- [ ] Keep optional complete-audio retention in the **consumer**, not hidden in the
  streaming library. whispr-lite may retain its 120-second capped recording for fallback.
- [ ] If streaming fails, the consumer must finish/cancel and settle model ownership
  before replaying audio through batch. It suppresses duplicate late final results.
- [ ] Leave LLM cleanup and prompt prefill outside the library. whispr-lite can consume
  changed partials to prefill its one llama-server slot and generate only after final ASR.
- [ ] Keep the model switchable internally, but ship Unified first. Nemotron/Ultra experiments
  need reviewed accuracy and resource evidence and a separate release decision.

**Exit:** repeated sessions preserve sample order and independent decoder state;
short/paused/cancelled recordings behave correctly; final flush, memory and accuracy
are measured; the app can consume streaming without starting an HTTP server.

## 9. Keep the standalone server independently usable

- [x] Update the executable to create/prepare a core engine, supply a server-appropriate
  configuration and run the existing transport adapter. Keep all CLI defaults/options.
- [x] Adapt HTTP routes to decode uploads as before and pass 16 kHz samples into the
  same batch operation used by library consumers.
- [x] Keep the old `TranscriptionService` name as a narrow internal adapter if useful
  during migration; do not maintain a second queue or inference implementation.
- [x] Convert structured core results into the existing response formats and actual
  duration fields. Map new typed errors at the transport boundary without exposing
  arbitrary model diagnostics or private audio/transcript contents.
- [x] Propagate request cancellation when the framework provides it. A disconnected
  request must obey the same nonpreemptible model ownership rules as a cancelled app job.
- [x] Preserve model loading before ready success. Preparation failure cannot leave
  `/health` reporting success against an unusable engine.
- [x] Keep model selection and file decoding outside per-request hot paths where possible;
  do not reload/rewarm the model for each HTTP request.
- [x] Retain the new WebM overflow/metadata/padding guards and ffmpeg pipe-draining fix
  from the starting commit. Keep their regression tests in the server suite.
- [x] Preserve LaunchAgent/install improvements and paths. Core import/initialization
  must not install, start, stop or alter the server's user service.
- [x] Recheck README local-use/privacy statements if admission/cancellation behavior changes.
  The source library itself does not listen on any network interface.

**Exit:** a user can still clone this repository, build/install just the server and
use the original endpoints through OpenWhispr without installing whispr-lite.

## 10. Tests and performance evidence

### Core tests without model downloads

- [ ] PCM contract: empty, very short, exact minimum, duration cap, invalid/nonfinite
  samples, actual duration and preserved normalization.
- [ ] Preparation: repeated/concurrent prepare, progress order, missing offline cache,
  failed download/load/warm-up, cancelled preparation and recovery on a later attempt.
- [ ] Queue: FIFO, capacity/retained-sample limits, cancellation before admission, while
  queued and during fake nonpreemptible inference, failure and subsequent progress.
- [ ] Ownership: transcribe/startStreaming/unload conflicts; late completion cannot
  release another request's permit. Use controllable fake model barriers, not timing sleeps.
- [ ] Streaming: sample offset errors, partial revision order, slow consumer coalescing,
  finish/cancel races, finish once, repeated cancel, empty recording, limits and reset.
- [ ] Public API: examples compile with ordinary imports, strict concurrency enabled,
  without `@testable`, Hummingbird, server startup or microphone permission.

Keep test seams private/internal where possible. Server tests can inject a small
transcribing adapter rather than requiring a public model-loading bypass in the SDK.
Maintain only tests that verify meaningful semantics and failure boundaries.

### Existing server regression coverage

- [ ] Keep WAV/other supported decode tests and short-upload padding tests.
- [ ] Keep JSON/text/verbose_json, missing file, malformed multipart, unsupported format,
  model list and health behavior checks.
- [ ] Keep WebM metadata/padding/overflow/empty-packet regression tests, ffmpeg noisy-pipe
  test and the sample-exact alignment test against ffmpeg where supported.
- [ ] Add queue-full/cancellation/error-mapping tests for any deliberately new behavior.
- [ ] Run actual CLI help and standalone startup against a prepared model as an optional
  smoke test. Ordinary CI must not require model downloads.

### Separate consumer and resource packaging

- [ ] Add `Examples/CoreConsumer` as a separate package that depends on the public product
  using a local path during development. It must not import internal server targets.
- [ ] Add a clean temporary consumer build by Git URL plus the exact candidate release
  revision/tag. A package's own tests are insufficient proof of external consumption.
- [ ] Verify dependency/module visibility and the built executable's linkage. Root-level
  resolution may fetch server packages, but the app must not require an HTTP server process.
- [ ] Verify FluidAudio's resource bundles/binary dependencies are included in a real app
  assembly and standalone executable distribution. A library that builds but cannot find
  `Bundle.module` resources at runtime is not ready for whispr-lite.
- [ ] Inspect optional traits in FluidAudio's version-specific Swift 6.2 manifest. Disable
  unrelated optional components only when verified unnecessary for batch/streaming ASR;
  avoid trading smaller downloads for changed transcription behavior.

### Optional model-backed benchmarks

- [ ] Preserve a synthetic corpus covering short phrases, 8- and 25-second recordings,
  sentence endings, soft speech, pauses and corrections. Record model/configuration identity.
- [ ] Run release builds. Compare pre-refactor versus extracted-core batch output, then
  core versus HTTP from identical PCM. Separate encoding/decode/transport/queue/inference.
- [ ] Interleave configurations and report raw samples plus median/p90/p95, at least
  30 warm observations per condition. Report startup and 90-second/5-minute/25-minute
  idle cases separately rather than averaging them into the warm result.
- [ ] Test streaming from different chunk sizes and final boundaries. Compare final
  results to batch and reviewed fixtures; disagreement alone is not ground-truth WER.
- [ ] Measure startup, final flush, physical footprint, dual residency, CPU/wakeups and
  sustained streaming compute. A faster release can still cost more energy while speaking.
- [ ] Require no material batch inference regression. Start with a 5 ms or 5% investigation
  threshold for extraction overhead, using enough repetitions to distinguish it from noise.
- [ ] Preserve the README's historical measurements; add dated reports for new results.
  Do not claim model speedups from merely avoiding HTTP or describe partial lag as final latency.

**Exit:** core/HTTP tests, external consumer builds and runtime resources pass;
model-backed parity and performance evidence are recorded before choosing the app default.

## 11. CI, documentation and release packaging

### CI and developer commands

- [ ] Extend the existing Apple Silicon macOS 15/26 CI and Swift 6.2 checks; preserve
  its full decoder tests and release executable build.
- [ ] Run core/server tests and compile the separate library consumer. If current runner
  images/toolchain paths change, fix that explicitly rather than weakening the checks.
- [ ] Keep ordinary CI independent of speech-model downloads and microphone permissions.
  Make model parity/performance runs opt-in with documented cache preparation.
- [ ] Keep `make build` building the standalone release executable and `make test` running
  the relevant suites. Add focused core/consumer/benchmark commands where they help.
- [ ] If distributing compiled server releases, inspect dynamic-library and resource
  requirements and assemble a versioned arm64 archive containing required bundles/notices.
  A copied executable alone is sufficient only after that runtime check passes.

### Documentation

- [ ] Add separate README sections for standalone installation and library integration.
- [ ] Document supported tools/macOS/architecture, PCM format, preparation/cache policy,
  threading/backpressure, cancellation limits, streaming lifecycle and limits.
- [ ] Add runnable batch and streaming consumer examples with expected error handling.
- [ ] Explain that first preparation may download and compile model assets; subsequent
  use can operate offline from a valid cache.
- [ ] Explain that models are not bundled with source releases and that an ASR package
  does not request a microphone permission, manage hotkeys or paste text.
- [ ] Preserve/update `LICENSE` and `THIRD_PARTY_NOTICES.md`, including explicit swift-log
  and any redistributed binary/resource notices. Keep model license/attribution distinct
  from the repository's MIT license; do not invent relicensing rights.

### Versioning and SwiftPM distribution

SwiftPM consumes this Git repository and its `Package.swift`. There is no requirement
to upload the code to a central SwiftPM registry. Package indexing/discovery is optional.

- [ ] Publish a first tagged batch-library release, provisionally `v0.1.0`, after checking
  that the tag is unused and all batch/standalone/consumer gates pass.
- [ ] Add streaming in a subsequent tagged release, provisionally `v0.2.0`, with clear
  pre-1.0 API compatibility notes. Do not wait for every streaming optimization to make
  the batch library available to whispr-lite.
- [ ] Pin consumers to the tested exact tag or commit and commit their resolved dependency
  state. Review upstream upgrades separately from the extraction.
- [ ] A private repository is usable with authenticated Git access by builders; a public
  repository allows ordinary URL-based resolution. Do not change visibility as part of
  the refactor without an explicit repository-owner decision.
- [ ] Test the candidate revision from a clean consumer clone/cache, and test the actual
  tag after publication. GitHub release notes should state library and server behavior.
- [ ] Retain the independently buildable server at every tagged library release.
- [ ] Publishing, tagging and pushing happen during implementation/release work; this
  planning task does not perform those actions.

Example consumer manifest fragment **after** the corresponding tag has been released:

```swift
dependencies: [
    .package(
        url: "https://github.com/Bigsy/parakeet-ane-server.git",
        exact: "0.1.0"
    )
],
targets: [
    .target(
        name: "WhisprLiteCore",
        dependencies: [
            .product(name: "ParakeetCore", package: "parakeet-ane-server")
        ]
    )
]
```

That manifest references a source package in SwiftPM's managed checkout. It is not
binary-only distribution, and it does not copy ASR source into the consumer repository.
XCFramework packaging can be revisited if binary-only consumption becomes a requirement.

## 12. Handoff back to whispr-lite

Once the batch library is released, update the app's plan/implementation to match this
architecture. Its original plan described HTTP batch plus a future WebSocket; the new
default path should be direct library calls, with existing HTTP batch as an optional fallback.

| This repository owns | whispr-lite owns |
|---|---|
| Models, preparation/cache and ASR capabilities | Application readiness display and microphone capture/conversion |
| Batch and streaming inference | Hotkey, pre-roll and exact capture start/end |
| Bounded model queue, cancellation and session reset | Dictation session/generation and suppressing stale insertion |
| ASR partial/final results and timings | llama-server cleanup, dictionary/prompt and optional partial prefill |
| Standalone HTTP/decoding/CLI | Media pause leases, focus/clipboard handling and text insertion |
| Public package API, tests and release tags | App bundling, signing, preferences and user-facing recovery |

- [ ] Give the app the exact package version, public examples, preparation states,
  limits/error categories, PCM contract and streaming/fallback behavior.
- [ ] App capture produces 16 kHz mono Float32 samples. Batch passes one owned buffer;
  streaming passes contiguous chunks through a serial sender outside the audio callback.
- [ ] Prepare the selected ASR mode before recording is enabled. The app should expose
  first-use model download/load status, not hide it in the first dictation.
- [ ] Avoid loading the same ASR model in both the app and standalone server accidentally.
  Keep service changes explicit in the app's migration setup; the core library never
  stops another process's LaunchAgent.
- [ ] Keep llama-server separate initially, using the existing tuned Gemma configuration.
  The app owns one cleanup/prefill slot; ASR does not need to know about cleanup prompts.
- [ ] Do not add a WebSocket or raw-PCM HTTP endpoint solely for the app. Add them later
  only if an actual external-server consumer requires streaming/raw PCM transport.
- [ ] Keep direct-library versus HTTP fallback selectable during rollout. Reverting to
  the server should not require copying source, deleting model caches or retuning models.

## 13. Delivery order and definition of done

| Milestone | Depends on | Completion gate |
|---|---|---|
| M0 — Baseline | — | New main checked, existing tests/build recorded, outputs/HTTP fixtures frozen. |
| M1 — Extract core | M0 | Public library product builds; standalone uses it; decoder fixes retained. |
| M2 — Preparation and batch API | M1 | Sample contract, progress/readiness/errors and direct PCM example work. |
| M3 — Queue and cancellation | M2 | Bounded operations, safe nonpreemptible ownership and race tests pass. |
| M4 — Batch library release | M3 | HTTP parity, consumer/resource checks, benchmarks/docs and versioned dependency ready. |
| M5 — Streaming spike | M4 | Pinned manager's accuracy, final flush, chunk path and residency measured. |
| M6 — Streaming sessions | M5 | Ordered bounded session API, partials, finish/cancel/reset and edge tests pass. |
| M7 — Streaming release | M6 | Consumer example, measured quality/resources, release notes and app handoff ready. |

Review each milestone as a small change. Complete extraction and batch consumption
before adding streaming; measure upstream behavior before creating a large session API.

The work is complete when:

- [ ] Another macOS package can resolve a tagged dependency and call `ParakeetCore`
  in-process with 16 kHz PCM, without copied ASR source or an HTTP server.
- [ ] Model preparation/readiness and cancellation are explicit, tested and usable by a GUI app.
- [ ] Streaming supports sequential repeated recordings with bounded state and one
  final result, and has measured quality, final-flush latency and memory behavior.
- [ ] The standalone executable still builds/installs independently and serves the
  existing OpenWhispr-compatible batch API with current decoder regression protection.
- [ ] CI, consumer examples, packaging/resources, documentation, licenses and dependency
  version information are sufficient for a fresh developer checkout to reproduce the result.

## 14. Primary references

Use the checked source and official documentation when implementing. Confirm API details
against the pinned versions; the outline above proposes this project's public API.

- [Starting source revision](https://github.com/Bigsy/parakeet-ane-server/tree/d4e9a8ab35f71259776c8e9c282a42796082a1f5)
- [SwiftPM products, targets and dependencies](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)
- [Pinned Unified streaming manager](https://github.com/FluidInference/FluidAudio/blob/503b4bd1bbf7220882de39fe8ae6716aae4132da/Sources/FluidAudio/ASR/Parakeet/Unified/StreamingUnifiedAsrManager.swift)
- [Pinned Unified batch manager](https://github.com/FluidInference/FluidAudio/tree/503b4bd1bbf7220882de39fe8ae6716aae4132da/Sources/FluidAudio/ASR/Parakeet/Unified)
- [Dependency and model notices](THIRD_PARTY_NOTICES.md)
- [Existing measurements and standalone usage](README.md)

Start with **M0**, then **M1**. The first deliverable for whispr-lite is the tagged,
tested batch library at **M4**; streaming follows without breaking standalone use.
