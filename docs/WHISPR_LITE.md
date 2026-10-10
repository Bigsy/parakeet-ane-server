# whispr-lite integration handoff

Target `ParakeetCore` from this repository with Swift 6.2+, Apple Silicon and macOS
14+. The published exact package versions are `0.1.0` (batch) and `0.2.0` (batch plus
Unified streaming). Both tags were verified with fresh anonymous consumer builds
and real inference. Use `0.2.0` with batch as the initial mode; streaming is optional. Commit the app's own Package.resolved. The runnable public example is
[CoreConsumer](../Examples/CoreConsumer); API/lifecycle details are in the [README](../README.md).

```swift
.package(url: "https://github.com/Bigsy/parakeet-ane-server.git", exact: "0.2.0")
// Target dependency:
.product(name: "ParakeetCore", package: "parakeet-ane-server")
```

Start with a prepared batch engine and `transcribe(PCM16kMono(samples: ownedAudio))`.
Show preparation stages on MainActor, enable recording only when ready and expose
missing-cache/download/preparation errors with retry. First use can download/compile;
`requireCached` and an explicit cache root allow offline operation. Model weights
are separate assets, not part of the source release. The default Unified int8
configuration and dependency pins are unchanged.

Capture/mix/resample to 16,000 Hz mono Float32 outside the library. An audio callback
hands owned buffers to a serial worker; it must not await ASR. Keep the app's 120-second
hotkey safety timer, recording generation and optional capped full-audio buffer.
Batch supplies one buffer. Streaming selects `.streaming` before preparation, calls
`startStreaming()`, sends 320/640-sample chunks with contiguous zero-based offsets,
and treats `finish()` as authoritative. Partials are revised full snapshots for UI
or optional llama-server prefill, never committed insertion. Filter updates/finals by
the app's current generation as well as session UUID.

The defaults are 120 seconds per recording, one-second maximum streaming chunk,
eight waiting jobs and 240 seconds of waiting PCM. Queue overflow and duration errors
are explicit. The consumer can configure limits; it must handle `.queueFull`, `.busy`,
`.cancelled`, deadlines and inference/preparation failures. Cancelling an accepted
chunk cancels its whole recording. Cancel the session and await `waitForSettlement()`
before fallback: CoreML may still be running after the caller stops waiting.

One engine holds one selected mode. To replay retained PCM after a streaming error,
cancel/settle, unload and prepare a batch engine; keep duplicate late final results
out of insertion. Observe `engine.state` and `isBusy`; reset failure needs preparation
retry. `engine.cancelStreaming()` recovers a recording whose session reference was
abandoned. Observer cancellation alone does not stop recording.

Retain FluidAudio's bundle and third-party notices when bundling/signing the app.
Check Xcode's generated Bundle.module lookup location in the actual app distribution;
this repository's manually assembled CLI app places the bundle at the app root.
Do not assume a linked executable is sufficient. The clean-consumer verification
script demonstrates a real app assembly without HTTP/server modules.

The app owns microphone permissions, hotkeys/pre-roll, media pause leases, focus,
clipboard/Accessibility insertion and llama-server cleanup using its existing Gemma
configuration. Keep one cleanup/prefill slot. No raw-PCM HTTP/WebSocket endpoint is
needed for direct integration. Keep HTTP fallback selectable during rollout and make
service changes explicit; the library never modifies another process's LaunchAgent.
Avoid accidentally preparing models in both app and server. This handoff does not
change the sibling app repository.

Measured synthetic fixtures preserve all batch words in streaming, with one final
period difference. Streaming spends more compute during capture despite a short
residual flush. See [measurements](../bench/results/2026-10-09.md); retain batch as the
initial default pending broader reviewed accuracy and energy evidence.
