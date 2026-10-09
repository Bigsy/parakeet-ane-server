#!/usr/bin/env python3
"""Smoke the assembled server, then compare HTTP against the identical raw PCM corpus."""
import json
from pathlib import Path
import subprocess
import socket
import time
import urllib.request
root = Path(__file__).resolve().parent.parent
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    port = listener.getsockname()[1]
url = f'http://127.0.0.1:{port}'
log = (root / '.build/http-smoke.log').open('w')
server = subprocess.Popen([str(root / '.build/distribution/parakeet-ane-server-batch-candidate-macos-arm64/parakeet-ane-server'), '--port', str(port), '--cache-root', str(root / '.build/bench-models'), '--offline'], stdout=log, stderr=log)
try:
    for attempt in range(1200):
        if server.poll() is not None:
            raise RuntimeError('Server exited during preparation; inspect .build/http-smoke.log')
        try:
            with urllib.request.urlopen(url + '/health', timeout=1) as response:
                assert json.load(response) == {'status': 'ok'}
                break
        except OSError:
            time.sleep(0.1)
    else:
        raise RuntimeError('Server readiness timeout')
    with (root / 'bench/results/http.jsonl').open('w') as observations:
        for fixture in sorted((root / '.build/bench-corpus').glob('*.wav')):
            body = b'--bench\r\nContent-Disposition: form-data; name="file"; filename="fixture.wav"\r\nContent-Type: audio/wav\r\n\r\n' + fixture.read_bytes() + b'\r\n--bench--\r\n'
            for iteration in range(30):
                start = time.monotonic_ns()
                request = urllib.request.Request(url + '/v1/audio/transcriptions', body, {'Content-Type': 'multipart/form-data; boundary=bench'})
                with urllib.request.urlopen(request, timeout=30) as response:
                    result = json.load(response)
                milliseconds = (time.monotonic_ns() - start) / 1e6
                observations.write(json.dumps({'fixture': fixture.stem + '.f32le', 'iteration': iteration, 'text': result['text'], 'milliseconds': milliseconds}) + '\n')
            print(fixture.stem, flush=True)
finally:
    server.terminate()
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill(); server.wait()
    log.close()
