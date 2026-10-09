# Opt-in model measurements

Ordinary `swift test` never downloads models. This package holds frozen baseline
batch wrappers from `d4e9a8a` and a public-core consumer; it is not app-vendored ASR.
Run on Apple Silicon macOS with Swift 6.2 and ffmpeg. Outputs contain only synthetic
speech transcripts, so they can be reviewed and shared without private recordings.

```sh
python3 bench/generate.py
swift build -c release --package-path bench --disable-keychain
# Explicit first-use preparation: downloads to the workspace cache, not the default user cache.
bench/.build/release/Benchmark prepare .build/bench-models unused
python3 bench/run-batch.py
bench/.build/release/Benchmark prepare-streaming .build/bench-models unused
python3 bench/run-streaming.py
make build
./scripts/package-server.sh batch-candidate
python3 bench/run-http.py
python3 bench/summarize.py
```

Run timing conditions sequentially on an idle machine. Avoid simultaneous builds,
downloads or inference; report those conditions if they occur. Raw JSONL observations,
CPU/RSS logs and dated reports live in `results/`. `run-batch.py` alternates prepared
baseline/core processes and uses the identical PCM/model cache. `run-http.py` starts
and stops only its own test server on a free loopback port; it never changes launchd.
Model assets and generated speech stay in ignored `.build/` directories.

Upstream streaming uses a separate encoder with `[70,13,13]` context, int8 CPU+ANE,
and no VAD splitting. The spike runs 20 ms, 40 ms and one-second chunks, drains token
observations and measures residual final flush separately. This is not a real-time
microphone capture benchmark. Keep batch as the initial app default until broader
accuracy and sustained compute/energy measurements justify a switch. Cache sharing
does not imply model execution/residency sharing.

Clean consumption and app resources can be checked with:

```sh
python3 scripts/verify-consumer.py
# Or test a published candidate/release using its exact Git revision:
python3 scripts/verify-consumer.py GIT_URL REVISION /path/to/Models audio.f32le
```

The verification script builds a fresh independent consumer package, excludes server
modules from its build/linkage, copies the required bundle into a macOS app assembly
and checks resource access. It never commits or tags the working repository.
