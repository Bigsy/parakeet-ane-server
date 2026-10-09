#!/usr/bin/env python3
"""Generate reproducible synthetic speech locally; no personal recordings."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

output = Path(sys.argv[1] if len(sys.argv) > 1 else '.build/bench-corpus')
output.mkdir(parents=True, exist_ok=True)
ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
fixtures = {
    'short': ('Please send it today.', None, 1),
    'eight': ('Could you send the revised document before lunch? I will review it this afternoon.', 8, 1),
    'twenty-five': ('I have reviewed the latest version of the document. The introduction is clear, but we should update the examples before sending it to the team. Please include the revised figures and add a short explanation of the next steps. We can discuss any remaining questions tomorrow morning.', 25, 1),
    'ending': ('Is the meeting still scheduled for Thursday?', None, 1),
    'soft': ('Please remember to attach the final report.', None, 0.1),
    'paused': ('Please send the draft. [[slnc 2500]] And include the figures. [[slnc 1500]] Thank you.', None, 1),
    'correction': ('The meeting is on Tuesday, sorry, I mean Thursday, at half past nine.', None, 1),
}
for name, (text, duration, volume) in fixtures.items():
    aiff = output / f'{name}.aiff'
    subprocess.run(['say', '-r', '180', '-o', str(aiff), text], check=True)
    command = [ffmpeg, '-nostdin', '-v', 'error', '-y', '-i', str(aiff), '-af', f'volume={volume},apad' if duration else f'volume={volume}']
    if duration:
        command += ['-t', str(duration)]
    command += ['-ar', '16000', '-ac', '1', '-c:a', 'pcm_f32le', str(output / f'{name}.wav')]
    subprocess.run(command, check=True)
    subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-y', '-i', str(output / f'{name}.wav'), '-f', 'f32le', str(output / f'{name}.f32le')], check=True)
    aiff.unlink()
(output / 'fixtures.json').write_text(json.dumps(fixtures, indent=2) + '\n')
