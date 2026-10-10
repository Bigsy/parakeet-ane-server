# parakeet-ane-server

An in-process Swift ASR library and OpenAI-compatible speech-to-text server for macOS that run NVIDIA's Parakeet
models on the Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio).

Built as a faster local transcription backend for [OpenWhispr](https://openwhispr.com),
but anything that speaks `POST /v1/audio/transcriptions` can use it.

Experimental software for local dictation on a trusted Mac.

## Why

OpenWhispr's built-in Parakeet runs on the CPU through sherpa-onnx in a process that
macOS happily swaps out between dictations. Same model (Parakeet Unified 0.6B), same
M4 Pro, warm, end to end over HTTP:

| Clip | OpenWhispr built-in (CPU)  | This server (ANE) |
|------|---------------------------:|------------------:|
| 8 s  | ~170 ms (~500 ms swapped)  | ~70 ms            |
| 25 s | ~530 ms                    | ~175 ms           |

This server's numbers include decoding the WebM/Opus uploads browsers record;
OpenWhispr's built-in was fed raw samples, so its numbers don't. Each upload is
transcribed in one pass with full context: nothing is split on pauses, so short
phrases between pauses aren't dropped. [Tuning notes](#tuning-notes) has how it got
here and what didn't work.

## Install

Needs macOS 14+, Apple Silicon and a Swift 6.2+ toolchain (Xcode 26+).
Check `swift --version`; the pinned dependencies require Swift 6.2.
ffmpeg (`brew install ffmpeg`)
is optional: it handles Ogg uploads and any WebM the built-in reader can't.

```sh
git clone https://github.com/Bigsy/parakeet-ane-server.git
cd parakeet-ane-server
make install
```

This builds a release binary, copies it to `~/.local/bin`, and installs a LaunchAgent
(`com.hedworth.parakeet-ane`) that starts the server at login on `127.0.0.1:11435`.
The first start downloads the CoreML models (~600 MB) into
`~/Library/Application Support/FluidAudio/Models` and compiles them for the Neural
Engine (~12 s once downloaded). Later starts take well under a second.

`make logs` follows the log, `make restart` restarts it, `make uninstall` removes it.

### OpenWhispr

Settings > Transcription > Self-hosted > OpenAI-compatible:

- URL: `http://127.0.0.1:11435/v1`
- Model: anything (the server runs one model and ignores the name)

## API

| Endpoint | |
|----------|-|
| `POST /v1/audio/transcriptions` | Multipart upload with a `file` field. `response_format` may be `json` (default), `text` or `verbose_json`. `model`, `language` and `prompt` are accepted and ignored. |
| `GET /v1/models` | The loaded model. |
| `GET /health` | `{"status":"ok"}` once the model is loaded. |

```sh
curl -F file=@clip.wav http://127.0.0.1:11435/v1/audio/transcriptions
```

Uploads are identified by their bytes, not their name or content type. WAV, AIFF,
CAF, FLAC, MP3 and M4A decode through Core Audio. WebM/Opus (single track, unlaced or
fixed-laced, one frame duration: what browsers write) is demuxed in-process and decoded
by Core Audio's Opus decoder. Ogg, and any WebM outside that, go through ffmpeg.

## Options

```
--model <unified|ultra|v2|v3>   Model to serve (default: unified)
--host <host>                   Address to bind (default: 127.0.0.1)
--port <port>                   Port (default: 11435)
--ffmpeg <path>                 ffmpeg binary (default: first found)
--log-transcripts               Log transcript text (default: off)
--log-level <level>             Log level (default: info)
```

| Model | Notes |
|-------|-------|
| `unified` | Parakeet Unified 0.6B. English, punctuation and capitals. Same model as OpenWhispr's built-in Parakeet. |
| `ultra` | Moondream's post-trained Parakeet TDT v3. 25 languages, lower WER than v3 on hard audio. |
| `v2` | Parakeet TDT 0.6B v2, English only. |
| `v3` | Parakeet TDT 0.6B v3, 25 European languages. |

Requests are processed one at a time, with at most eight waiting jobs by default. Transcript text is not logged unless
`--log-transcripts` is set; each request logs only audio length, format and timings.

## Local use and privacy

The default listener is `127.0.0.1`. There is no authentication, TLS,
or rate limiting. The model queue is bounded. Local processes can submit audio. Changing `--host` to a
LAN address or `0.0.0.0` lets other reachable clients submit audio as well; use an
authenticated reverse proxy and access controls if you need remote access.

Uploads are limited to 100 MiB including multipart overhead. Decoded audio is held
in memory. The default limit is one hour per request and two hours across waiting
jobs; `--max-audio-seconds`, `--max-queued-audio-seconds` and `--queue-capacity`
configure these limits. Decoding still happens before queue admission, so use trusted
clients and dictation-sized recordings. Audio exceeding the limit returns HTTP 413;
a full queue returns 503. Model failures return a sanitized 500 error. Startup fails
if preparation or warm-up fails. Cancelling a request discards its result; an active
CoreML operation retains ownership until it actually settles. WAV and other file-based decoding paths temporarily
write audio to the macOS temporary directory and remove it when decoding finishes.
Transcription runs locally; model downloads on first use require internet access.
`--log-transcripts` writes potentially private dictation to the service log.

## ParakeetCore integration

`ParakeetCore` is a SwiftPM library product for macOS 14+ on Apple Silicon, using
Swift 6.2+. It takes owned PCM directly in the application's process. It does not
start a listener, request microphone access, install a service, handle hotkeys or
clean up text with an LLM. Capture, resampling and text insertion belong to the app.

Use the public Git repository directly in Swift Package Manager. In Xcode, add
`https://github.com/Bigsy/parakeet-ane-server.git`, choose exact version **0.2.0**,
and select the **ParakeetCore** library product. A package manifest uses:

```swift
// Package.swift dependencies:
.package(url: "https://github.com/Bigsy/parakeet-ane-server.git", exact: "0.2.0")
// Your app/library target's dependencies:
.product(name: "ParakeetCore", package: "parakeet-ane-server")
```

Then `import ParakeetCore`. No registry upload or copied ASR source is needed.
[v0.1.0](https://github.com/Bigsy/parakeet-ane-server/releases/tag/v0.1.0) provides
batch; [v0.2.0](https://github.com/Bigsy/parakeet-ane-server/releases/tag/v0.2.0)
adds Unified streaming. Both exact versions passed fresh anonymous consumer builds,
app resource checks and real inference. Commit the consuming project's resolved
dependency state and review future upgrades, especially before 1.0.

For local development, depend on this repository by path (see
[CoreConsumer](Examples/CoreConsumer)). The manifest exports both products;
SwiftPM may fetch server dependencies while resolving the repository, but building
the core consumer does not compile/link Hummingbird, MultipartKit or the server.

```swift
import ParakeetCore

let engine = ParakeetEngine(configuration: .init(
    model: .unified,
    downloadPolicy: .allow))
try await engine.prepare { progress in
    // Unspecified executor: dispatch readiness UI updates to MainActor.
    print(progress.stage)
}
let pcm = try PCM16kMono(samples: capturedSamples)
let result = try await engine.transcribe(pcm)
print(result.text) // raw ASR text, with existing whitespace trimming
try await engine.unload()
```

PCM means **16,000 samples/second, mono Float32**, conventionally -1...1, without a
WAV header or compression. Finite samples outside that range are preserved. Rate
and channel count cannot be inferred from a sample array: the caller must convert
capture audio first. NaN/infinity and oversized buffers are rejected. Empty audio
returns empty text without inference; nonempty batch clips shorter than one second
are padded once, while `actualAudioDuration` continues to describe the input.

Constructing/importing an engine performs no downloads. `prepare()` checks the
cache, downloads if allowed, loads/compiles and warms once. Progress fractions are
only upstream download/compile progress; loading and warm-up can have no fraction.
The default cache is `~/Library/Application Support/FluidAudio/Models`.
`cacheRoot` changes that base directory, preserving repository-named subdirectories.
`downloadPolicy: .requireCached` uses local loading only, with no global upstream
network setting and no network recovery. Missing/incomplete caches fail explicitly.
Corrupt model loads fail without automatically deleting shared caches. Preparation
uses a nonblocking lock for cooperating ParakeetCore processes; other FluidAudio
users do not participate in that lock. Do not manually clear a cache in use.

Repeated preparation after success is a no-op; concurrent preparation returns
`.busy`. Warm-up/load failure leaves `.failed`, and preparation can be retried.
`state` is an actor snapshot; GUI readiness does not depend on an HTTP health probe.
All public input, configuration, results and errors are `Sendable`.

The library defaults to 120 seconds per recording, eight waiting jobs and 240 seconds
of waiting PCM. Configure sample limits explicitly for longer workloads. Queue wait
and inference timeouts are optional and distinct. `queueDuration`, `inferenceDuration`
and `totalDuration` use a monotonic clock and contain no transcript logging. The core
has no logging bootstrap or hidden text log; FluidAudio retains its own diagnostics.

Cancelling the caller removes queued audio promptly and throws `.cancelled`.
Cancellation during inference ends the caller's wait and suppresses late results,
but Swift task cancellation does **not** guarantee that CoreML/ANE stops immediately.
The next operation waits for actual completion. `unload()` rejects busy engines,
is idempotent when idle and releases model references; immediate OS memory recovery
is not guaranteed. Error categories distinguish readiness, cache/download/preparation,
invalid audio, limits, queue capacity, cancellation and inference failures.

Run the public consumer without model downloads:

```sh
make consumer
# A real batch run, reading little-endian raw Float32 PCM:
swift run -c release --package-path Examples/CoreConsumer CoreConsumer \
  --transcribe audio.f32le /path/to/Models --download
# Omit --download to require a valid offline cache.
```

SwiftPM builds FluidAudio's resource bundle and its default static NeMo dependency.
App distribution must copy `FluidAudio_FluidAudio.bundle` to the location expected
by its generated `Bundle.module` accessor and retain third-party notices. The SwiftPM
CLI accessor uses `Bundle.main.bundleURL` (the app root in a manually assembled
`.app`); Xcode app assembly may use `Contents/Resources`. `scripts/verify-consumer.py`
builds a clean Git-revision consumer, checks module isolation and verifies resources
in an actual app assembly. The standalone installer copies
resource bundles beside its executable; `make package VERSION=candidate` creates a
self-contained arm64 directory with resources and notices. Models remain separately
downloaded assets and are never bundled with this source package.

## Streaming with ParakeetCore

Unified supports streaming in `v0.2.0`; Ultra/v2/v3 remain batch-only. Prepare an
engine with `mode: .streaming`. One engine holds one model stack: changing mode
requires settling the session, unloading and preparing a new engine. The streaming
encoder differs from the batch encoder; a shared disk cache does not provide an
immediately prepared batch fallback.

```swift
let engine = ParakeetEngine(configuration: .init(mode: .streaming))
try await engine.prepare()
let session = try await engine.startStreaming()
let observer = Task {
    for try await update in session.updates {
        // Full provisional text; check sessionID before updating this recording's UI.
        print(update.revision, update.fullTranscript)
    }
}
do {
    var offset = 0
    // Run from a serial capture worker, outside the real-time microphone callback.
    for samples in ownedCaptureChunks {
        try await session.append(PCM16kMono(samples: samples), startingAt: offset)
        offset += samples.count
    }
    let final = try await session.finish()
    try await observer.value
    print(final.text) // authoritative raw ASR result; app performs cleanup/insertion
} catch {
    await session.cancel()
    await session.waitForSettlement()
    observer.cancel()
    _ = try? await observer.value
    throw error
}
try await engine.unload()
```

`append` accepts nonempty contiguous chunks, with sample offsets starting at zero.
The default maximum chunk is 16,000 samples, total recording 120 seconds, and waiting
queue eight waiting audio jobs/240 seconds of PCM. Finish is one additional
control operation queued behind accepted audio. Await each append from a serial sender; if using
concurrent senders, rejection leaves the offset unreserved so the caller can retry.
Overflow is explicit, never silent sample loss. Cancelling an accepted append cancels
the entire recording because dropping a chunk would leave a hole. Queue/inference
deadlines also end the recording. Nonpreemptible model work retains the engine until
reset settles; `unload()` returns `.busy` during that interval.

`finish()` drains accepted audio, flushes once, resets and releases the engine before
returning. Repeated finish returns the cached result; simultaneous finishes return
`.busy`. Empty recordings return empty text. Cancel is idempotent and clears unread
provisional updates. If cancellation wins before successful final completion, the
final result is suppressed; cancel after completion leaves the cached result intact.
Use `waitForSettlement()` after cancellation before fallback/unload. An abandoned
recording can also be cancelled through `engine.cancelStreaming()`.

Updates have a session UUID, increasing revision and full text snapshot. They retain
only the newest unread value for one observer, preserving bounded memory. Cancelling
the observer ends observation while recording continues. `receivedAudioPosition`
counts completed input; `processedAudioPosition` is nil because the pinned upstream
manager does not expose a decoded frontier. Partials can be revised, and must not
be inserted as committed dictation. No VAD segmentation splits pauses or corrections.

Chunks of 320/640 samples (20/40 ms) work without per-chunk padding or resampling.
The model processes larger windows as they become available; its default context
implies about 2.08 seconds of theoretical partial lag. `finalizationDuration` measures
residual flush only, `inferenceDuration` sums append/process/flush/reset work,
`queueDuration` is the final operation's queue wait, and `totalDuration` spans the
recording/session through reset. These describe different parts of the operation.

Run the public example with `--streaming` added to the command above. See the
[dated measurements](bench/results/2026-10-09.md) and
[whispr-lite integration handoff](docs/WHISPR_LITE.md). Streaming preserved words on
seven synthetic fixtures, with one final-period difference. It spends more compute
while speaking, so batch remains the conservative app default. The consumer owns
optional complete-audio retention and the safety timer; to fall back, cancel/settle,
unload the streaming engine and prepare batch before replaying retained PCM.

## Tuning notes

Measured on an M4 Pro (24 GB, macOS 26) with two synthetic dictations, an 8 s and a
25 s clip (macOS `say`, British voice), uploaded the way OpenWhispr does it: a
`multipart/form-data` POST of `audio/webm;codecs=opus`.

### Engine and model

| Option | 8 s | 25 s | Notes |
|---|---:|---:|---|
| OpenWhispr built-in: sherpa-onnx, CPU, 4 threads | ~170 ms | ~530 ms | 2.2 GB footprint, 2.0-2.2 GB of it seen swapped out; ~500 ms on the first request after |
| parakeet-mlx, GPU (TDT v2 bf16) | ~165 ms | ~295 ms | 3.3 GB peak; rejected |
| FluidAudio, Neural Engine (Unified int8) | ~75 ms | ~160 ms | processing time only; chosen |
| [macos-speech-server](https://github.com/dokterbob/macos-speech-server) (FluidAudio) | | | Not used: splits audio on VAD pauses and transcribes each piece without context (its open PR #36 documents dropped ~2 s phrases), and pins FluidAudio 0.13.5 (no Unified or Ultra) |

The default model is Unified so accuracy matches what OpenWhispr already gave.

### Decoding WebM/Opus

OpenWhispr uploads the raw `MediaRecorder` blob, so every dictation is WebM/Opus.

| Option | Verdict |
|---|---|
| ffmpeg subprocess (first version) | 40-54 ms per request, ~28 ms of it process startup; 90-160 ms after 90 s idle |
| AVFoundation `AVAudioFile` | Can't open Matroska/WebM |
| libopus | Works, but adds a C dependency for something macOS ships |
| Link ffmpeg's libraries | Heavy to build and ship for one container |
| **Minimal Matroska demuxer + Core Audio's Opus decoder** | **Chosen: 7 ms (8 s) / 23 ms (25 s), ~11 ms after idle** |

The demuxer (`WebMOpus.swift`) reads what browser recorders write: one Opus track,
unlaced or fixed-laced blocks, a constant frame duration, and the "unknown size"
Segments and Clusters of live recordings. Anything else, and Ogg, falls back to ffmpeg.

### Making the decode sample-exact

The first in-process decoder had the right length and level, but Parakeet dropped the
final "?" on the 8 s clip where ffmpeg's decode of the same Opus kept it.
Cross-correlating against ffmpeg found two offsets:

- **End: +17 ms of encoder padding.** Matroska `DiscardPadding` (828 samples at 48 kHz
  on the last block) tells decoders to drop it. ffmpeg does; we now do too.
- **Start: 2.5 ms over-trimmed.** Measured at 48 kHz before any resampling, Core Audio's
  Opus decoder already drops Opus's 120-sample decoder delay. It isn't reported by
  `AVAudioConverter.primeInfo` (0/0), and `primeMethod = .none` doesn't change it, so
  applying the full `OpusHead` pre-skip double-counted it. We apply `pre-skip - 120`.

The output now matches ffmpeg at lag 0, length within 2 samples, and the "?" is back.
`alignsSampleExactlyWithFFmpeg` checks this with white noise (a tone aligns at several
lags and would hide an offset), so a macOS change to the decoder delay fails the test
instead of quietly changing transcripts.

### Resampling

Decoding at 48 kHz, trimming, then resampling with FluidAudio's
`AudioConverter.resample` was correct but took decode to 47 ms / 160 ms: FluidAudio
configures Core Audio's Mastering algorithm at max quality. Decoding straight to 16 kHz
in one converter call keeps the converter's own latency compensation, so the 48 kHz
trims scale exactly, and brings decode back to 7 ms / 23 ms.

### Idle behaviour

After 90 s idle (three samples each, 8 s clip):

| | Decode | Transcription | Total |
|---|---:|---:|---:|
| Warm, back to back | 7 ms | ~62 ms | ~72 ms |
| After idle, ffmpeg decode | 91-162 ms | 98-150 ms | 241-275 ms |
| After idle, in-process decode | 11-12 ms | 110-113 ms | ~125 ms |
| After idle, in-process decode + keep-warm every 30 s | 24-27 ms | 118-138 ms | 145-166 ms |

The in-process decoder removed ffmpeg's idle penalty. The rest is macOS clocking the CPU
and Neural Engine down. A `--keep-warm` option that transcribed one second of silence
every 30 s while idle made no difference (those samples ran with the machine slightly
busier: back-to-back requests were 81-85 ms), and decode, which runs on the CPU and
isn't touched by the ping, slowed too. The power-down happens within seconds, and
pinging more often isn't worth the battery for ~50 ms, so the option was removed. The
startup warm-up stays: it avoids a slow first request after launch.

### Smaller findings

- Debug builds mislead: native WAV decode measured ~72 ms per second of audio under
  `swift test`, 1-4 ms in release.
- Model load is ~12 s the first time (CoreML compiles for the Neural Engine) and
  0.1-0.6 s once cached. The startup warm-up takes 45-67 ms.
- `launchctl bootout` returns before the job is gone, so reinstalling over a running
  service failed with `Bootstrap failed: 5`. `make install` now waits.

### In use

The first two real OpenWhispr dictations through it, alongside the llama.cpp cleanup
model:

| Audio | Decode | Transcription | Cleanup LLM | Total |
|---:|---:|---:|---:|---:|
| 2.4 s (first after ~23 min idle) | 30 ms | 267 ms | ~128 ms | ~425 ms |
| 3.5 s (6 s later) | 21 ms | 113 ms | ~204 ms | ~340 ms |

That morning the same dictations spent ~170-530 ms in transcription and ~372 ms in
cleanup, or 1.5-1.7 s after a long idle. The ~267 ms first transcription after a long
idle is the main thing left to look at.

## Development

```sh
make test    # unit and HTTP tests, using a stub model (no download needed)
make build
```

Install ffmpeg to run the WebM/Opus and Ogg tests; those tests are skipped if it is
absent. Core Audio's Opus decoder needs access to macOS codec services, so running
the tests inside a restrictive sandbox may fail. CI runs the full test suite and a
release build on Apple Silicon macOS 15 and 26 without downloading speech models.

## License and attribution

Library and server code: [MIT](LICENSE). Models and dependencies retain their upstream licenses.
The default Parakeet Unified model is CC-BY-4.0. NVIDIA created Parakeet, Fluid
Inference provides FluidAudio and the CoreML conversions, and Moondream provides
the Ultra post-training. See [third-party notices](THIRD_PARTY_NOTICES.md) for model
sources and license information.
