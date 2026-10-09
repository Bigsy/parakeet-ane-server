#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parent.parent
output = root / 'bench/results/streaming.jsonl'
with output.open('w') as observations:
    for fixture in sorted((root / '.build/bench-corpus').glob('*.f32le')):
        for chunk in [320, 640, 16000]:
            process = subprocess.run([str(root / 'bench/.build/release/Benchmark'), 'streaming', str(root / '.build/bench-models'), str(fixture), str(chunk), '30'], capture_output=True, text=True, check=True)
            for line in process.stdout.splitlines():
                if line.startswith('{'):
                    json.loads(line); observations.write(line + '\n')
            observations.flush()
            print(f'{fixture.stem}: {chunk}', flush=True)
