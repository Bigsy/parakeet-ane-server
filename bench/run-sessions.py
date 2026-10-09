#!/usr/bin/env python3
"""Public-library streaming parity, repeated sessions and real-time pacing."""
import json
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parent.parent
binary = root / 'bench/.build/release/Benchmark'
cache = root / '.build/bench-models'
corpus = root / '.build/bench-corpus'
with (root / 'bench/results/sessions.jsonl').open('w') as observations:
    for fixture in sorted(corpus.glob('*.f32le')):
        for chunk in [320, 640, 16000]:
            result = subprocess.run([str(binary), 'session', str(cache), str(fixture), str(chunk), '30'], capture_output=True, text=True, check=True)
            for line in result.stdout.splitlines():
                if line.startswith('{'):
                    json.loads(line); observations.write(line + '\n')
            observations.flush(); print(f'{fixture.stem}: {chunk}', flush=True)
with (root / 'bench/results/realtime-sessions.jsonl').open('w') as observations:
    for name in ['eight', 'twenty-five']:
        result = subprocess.run([str(binary), 'session-realtime', str(cache), str(corpus / f'{name}.f32le'), '320', '3'], capture_output=True, text=True, check=True)
        for line in result.stdout.splitlines():
            if line.startswith('{'):
                json.loads(line); observations.write(line + '\n')
        observations.flush(); print(f'{name}: real-time', flush=True)
