#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import statistics
from collections import defaultdict
root = Path(__file__).resolve().parent.parent
results = root / 'bench/results'

def observations(name):
    return [json.loads(line) for line in (results / name).read_text().splitlines() if line.startswith('{')]

def quantile(values, fraction):
    values = sorted(values)
    return values[min(len(values) - 1, int((len(values) - 1) * fraction))]

batch = defaultdict(list)
for observation in observations('batch.jsonl'):
    batch[observation['fixture'], observation['implementation']].append(observation)
http = defaultdict(list)
for observation in observations('http.jsonl'):
    http[observation['fixture']].append(observation)
stream = defaultdict(list)
for observation in observations('streaming.jsonl'):
    stream[observation['fixture'], observation['chunkSamples']].append(observation)
lines = ['# Measurements — 9 October 2026', '',
'Host: arm64 macOS 27.0 (26A428), Apple Swift 6.2.3; release builds. FluidAudio 0.17.7 / `503b4bd1bbf7220882de39fe8ae6716aae4132da`. Unified int8 offline and streaming `[70,13,13]`, default upstream CPU + Neural Engine encoder and CPU decoder/joint. Model repo: `FluidInference/parakeet-unified-en-0.6b-coreml`, downloaded from upstream main on this date; component SHA-256 identities below.', '',
'Baseline sources are frozen from `d4e9a8a`. Both paths load the same cached assets and owned PCM; the legacy service retains its original padding/queue/whitespace behavior. Runs alternate separate prepared processes (30 warm observations per condition per fixture). HTTP sends Float32 WAV constructed from the same raw PCM. Synthetic speech uses this host\'s default `say` voice at 180 words/minute. No personal recordings.', '',
'## Batch and HTTP', '', '| Fixture | Baseline median ms | Core median / p90 / p95 ms | HTTP median ms | Text parity |', '|---|---:|---:|---:|---|']
for fixture in sorted(http):
    legacy = batch[fixture, 'baseline']; core = batch[fixture, 'core']; uploaded = http[fixture]
    baseline_values = [o['milliseconds'] for o in legacy]
    core_values = [o['milliseconds'] for o in core]
    parity = len({o['text'] for o in legacy + core + uploaded}) == 1
    lines.append(f"| {fixture} | {statistics.median(baseline_values):.2f} | {statistics.median(core_values):.2f} / {quantile(core_values,.9):.2f} / {quantile(core_values,.95):.2f} | {statistics.median(o['milliseconds'] for o in uploaded):.2f} | {'exact' if parity else 'DIFF'} |")
repeat = defaultdict(list)
for observation in observations('long-clip-isolated.jsonl'):
    repeat[observation['implementation']].append(observation['milliseconds'])
lines += ['', f"Isolated 25-second repeat (30 observations each): baseline median {statistics.median(repeat['baseline']):.2f} ms; core median {statistics.median(repeat['core']):.2f} ms."]
lines += ['', 'First assembled-server preparation took 24.40 seconds on this host. This includes load/compilation and warm-up, and is not a guaranteed cached startup latency.', '',
'Initial long-clip timing overlapped other validation work and triggered the 5 ms / 5% investigation threshold. The repeated raw long-clip comparison is retained separately; the isolated repeat above is the release timing comparison. These observations do not prove a model speedup. HTTP timing includes client/transport/decode; direct inference timing excludes those operations.', '',
'## Upstream streaming spike', '', '| Fixture | Chunk samples | Final flush median / p90 / p95 ms | Processing median ms | Final text vs batch |', '|---|---:|---:|---:|---|']
for (fixture,chunk), values in sorted(stream.items()):
    finish = [o['finishMilliseconds'] for o in values]
    exact = {o['text'] for o in values} == {o['text'] for o in batch[fixture,'core']}
    lines.append(f"| {fixture} | {chunk} | {statistics.median(finish):.2f} / {quantile(finish,.9):.2f} / {quantile(finish,.95):.2f} | {statistics.median(o['processMilliseconds'] for o in values):.2f} | {'exact' if exact else 'final period added'} |")
lines += ['', 'Streaming keeps all words on these synthetic fixtures, including pauses and corrections; the 25-second final result adds a period missing from batch. This small corpus is not a ground-truth WER benchmark. Full partial lag is governed by upstream\'s 2.08-second context, not by the caller\'s 20–40 ms transport chunks. Final flush and partial lag are different measurements.', '',
'`appendAudio` detects matching 16 kHz mono Float32 and extracts samples; it does not resample on that path. It still copies from AVAudioPCMBuffer, so a library wrapper must account for that cost. The upstream rolling buffer is bounded; optional complete recording retention belongs to the consumer.', '',
'The spike is an upstream API measurement; the public session implementation is measured separately below.', '']
sessions = defaultdict(list)
for observation in observations('sessions.jsonl'):
    sessions[observation['fixture'].removesuffix('.f32le'), observation['chunkSamples']].append(observation)
lines += ['## Public streaming sessions', '',
'630 observations: 30 sequential recordings per fixture/chunk combination in a prepared public engine. No HTTP imports, per-chunk padding or complete recording retention. These runs send audio as fast as operations permit; the next table uses wall-clock pacing.', '',
'| Fixture | Chunk samples | Flush median / p90 / p95 ms | Cumulative inference median ms | Final text vs batch |',
'|---|---:|---:|---:|---|']
for (fixture, chunk), values in sorted(sessions.items()):
    finish = [o['finishMilliseconds'] for o in values]
    exact = {o['text'] for o in values} == {o['text'] for o in batch[fixture, 'core']}
    lines.append(f"| {fixture} | {chunk} | {statistics.median(finish):.2f} / {quantile(finish,.9):.2f} / {quantile(finish,.95):.2f} | {statistics.median(o['inferenceMilliseconds'] for o in values):.2f} | {'exact' if exact else 'final period added'} |")
lines += ['', '### Paced capture compute', '',
'Three repeats each at 20 ms input pacing. CPU is process user + system time per recording, including append/processing/final reset; it excludes initial preparation. Wakeups use TASK_POWER_INFO deltas. This is a small compute probe, not an energy/battery measurement; shared ANE/system work is not fully attributed to process CPU.', '',
'| Fixture | Duration s | Flush median ms | Process CPU median s | Interrupt / platform-idle wakeups median | Footprint median MiB |',
'|---|---:|---:|---:|---:|---:|']
realtime = defaultdict(list)
for observation in observations('realtime-sessions.jsonl'):
    realtime[observation['fixture']].append(observation)
for fixture, values in sorted(realtime.items()):
    lines.append(f"| {fixture} | {values[0]['actualAudioDuration']:.2f} | {statistics.median(o['finishMilliseconds'] for o in values):.2f} | {statistics.median(o['userCPUSeconds'] + o['systemCPUSeconds'] for o in values):.3f} | {statistics.median(o['interruptWakeups'] for o in values):.0f} / {statistics.median(o['platformIdleWakeups'] for o in values):.0f} | {statistics.median(o['physicalFootprintBytes'] for o in values)/1048576:.2f} |")
lines += ['', '### Warmed mode residency', '',
'Each mode runs in a separate process with the same 25-second PCM. Batch transcribes it; streaming appends/processes/finishes/resets it. Both managers are loaded and exercised for dual mode. Values are one physical-footprint observation, not peak/system/ANE memory. Models can share mapped assets and CoreML retains caches. No dual-residency product option is justified by these measurements.', '',
'| Mode | Before load MiB | After actual inference/reset MiB |', '|---|---:|---:|']
for value in observations('warmed-residency.jsonl'):
    lines.append(f"| {value['mode']} | {value['baselineBytes']/1048576:.2f} | {value['warmedBytes']/1048576:.2f} |")
lines += ['', '`residency.json` retains the initial probe for transparency; its streaming manager was not warmed, so use the warmed observations above. Long idle 90-second/5-minute/25-minute runs, broader reviewed accuracy and battery/energy evaluation remain opt-in follow-up. The paced measurements cover repeated 8/25-second recordings, not hours of capture. Batch remains the conservative app default.', '', '## Fixture and model identities', '', '```json']
identities={}
for path in sorted((root / '.build/bench-corpus').glob('*.f32le')):
    identities[str(path.relative_to(root / '.build'))]=hashlib.sha256(path.read_bytes()).hexdigest()
for path in sorted((root / '.build/bench-models').rglob('*')):
    if path.is_file():
        identities[str(path.relative_to(root / '.build'))]=hashlib.sha256(path.read_bytes()).hexdigest()
lines += [json.dumps(identities, indent=2), '```', '']
(results / '2026-10-09.md').write_text('\n'.join(lines))
