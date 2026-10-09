# parakeet-ane-server

A small OpenAI-compatible speech-to-text server for macOS that runs NVIDIA's Parakeet
models on the Apple Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio).

Built as a faster local transcription backend for [OpenWhispr](https://openwhispr.com),
but anything that speaks `POST /v1/audio/transcriptions` can use it.

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

Needs macOS 14+, Apple Silicon and Xcode 16+ (Swift 6). ffmpeg (`brew install ffmpeg`)
is optional: it handles Ogg uploads and any WebM the built-in reader can't.

```sh
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

Requests are processed one at a time. Transcript text is not logged unless
`--log-transcripts` is set; each request logs only audio length, format and timings.

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
