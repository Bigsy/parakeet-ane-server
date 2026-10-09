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
| 8 s  | ~170 ms (~500 ms swapped)  | ~62 ms            |
| 25 s | ~530 ms                    | ~163 ms           |

Both measured with the WebM/Opus uploads browsers record. Those are demuxed and
decoded in-process (7-20 ms) rather than by spawning ffmpeg, which costs ~30 ms warm
and ~150 ms after the Mac has been idle.

Each upload is transcribed in one pass with full context. Nothing is split on pauses,
so short phrases between pauses aren't dropped.

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
Engine, which takes a minute. Later starts take about 12 s.

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
--keep-warm <seconds>           Re-warm the model after this long idle (default: off)
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

## Development

```sh
make test    # unit and HTTP tests, using a stub model (no download needed)
make build
```
