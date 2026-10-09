#!/usr/bin/env python3
"""Alternate release processes over identical owned PCM and one prepared cache."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
binary = root / 'bench/.build/release/Benchmark'
cache = root / '.build/bench-models'
corpus = root / '.build/bench-corpus'
output = Path(sys.argv[1] if len(sys.argv) > 1 else 'bench/results/batch.jsonl')
output.parent.mkdir(parents=True, exist_ok=True)
with output.open('w') as observations:
    for fixture in sorted(corpus.glob('*.f32le')):
        for mode in ['baseline', 'core', 'core', 'baseline']:
            process = subprocess.run(['/usr/bin/time', '-l', str(binary), mode, str(cache), str(fixture), '15'], capture_output=True, text=True, check=True)
            for line in process.stdout.splitlines():
                if line.startswith('{'):
                    json.loads(line)
                    observations.write(line + '\n')
            observations.flush()
            (output.parent / f'{fixture.stem}-{mode}-resources.txt').write_text(process.stderr)
            print(f'{fixture.stem}: {mode}', flush=True)
