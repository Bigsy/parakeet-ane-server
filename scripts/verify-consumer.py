#!/usr/bin/env python3
"""Verify a clean Git revision consumer, including a macOS .app assembly.

With no arguments, snapshot the working tree into a temporary Git repository.
For a published candidate: verify-consumer.py GIT_URL REVISION [MODEL_CACHE PCM_FILE] [--streaming]
The script never commits, tags or switches branches in the user's repository.
"""
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent

def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='parakeet-consumer-') as temporary:
    temp = Path(temporary)
    if len(sys.argv) >= 3:
        git_url, revision = sys.argv[1:3]
    else:
        snapshot = temp / 'parakeet-ane-server'
        snapshot.mkdir()
        files = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).decode().split('\0')
        for relative in files:
            source = root / relative
            if not relative or not source.is_file():
                continue
            destination = snapshot / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        run(['git', 'init', '-q', str(snapshot)])
        run(['git', '-C', str(snapshot), 'add', '.'])
        run(['git', '-C', str(snapshot), '-c', 'user.name=Parakeet verification', '-c', 'user.email=verification@localhost', 'commit', '-qm', 'Candidate snapshot'])
        revision = subprocess.check_output(['git', '-C', str(snapshot), 'rev-parse', 'HEAD'], text=True).strip()
        git_url = snapshot.as_uri()
    # Use the example shipped at the candidate: a batch tag must not be checked
    # with a later streaming example that imports APIs absent from that release.
    source_checkout = temp / 'source'
    run(['git', 'clone', '-q', '--no-checkout', git_url, str(source_checkout)])
    run(['git', '-C', str(source_checkout), 'checkout', '-q', revision, '--', 'Examples/CoreConsumer'])
    consumer = temp / 'consumer'
    shutil.copytree(source_checkout / 'Examples/CoreConsumer', consumer, ignore=shutil.ignore_patterns('.build', '.swiftpm'))
    manifest = consumer / 'Package.swift'
    # Test release tags through semantic-version resolution, not merely Git ref checkout.
    version = revision.removeprefix('v') if re.fullmatch(r'v?\d+\.\d+\.\d+', revision) else None
    requirement = f'exact: "{version}"' if version else f'revision: "{revision}"'
    manifest.write_text(manifest.read_text().replace('.package(path: "../..")', f'.package(url: "{git_url}", {requirement})'))
    log_path = root / '.build/consumer-git-verification.log'
    with log_path.open('w') as log:
        run(['swift', 'build', '-c', 'release', '--package-path', str(consumer), '--disable-keychain'], stdout=log, stderr=log)
    log_text = log_path.read_text()
    assert not any(f'Compiling {module}' in log_text or f'Emitting module {module}' in log_text for module in ['Hummingbird', 'MultipartKit', 'ParakeetANE'])
    binary_dir = consumer / '.build/release'
    run([str(binary_dir / 'CoreConsumer')])
    run([str(binary_dir / 'CoreConsumer'), '--check-resources'])
    symbols = subprocess.check_output(['nm', str(binary_dir / 'CoreConsumer')], text=True)
    assert 'Hummingbird' not in symbols and 'MultipartKit' not in symbols and 'ParakeetANE' not in symbols
    app = temp / 'CoreConsumer.app'
    executable = app / 'Contents/MacOS/CoreConsumer'
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary_dir / 'CoreConsumer', executable)
    with (app / 'Contents/Info.plist').open('wb') as info:
        plistlib.dump({'CFBundleExecutable': 'CoreConsumer', 'CFBundleIdentifier': 'local.parakeet.verification', 'CFBundlePackageType': 'APPL'}, info)
    # SwiftPM's CLI-generated Bundle.module accessor uses Bundle.main.bundleURL.
    # Xcode-generated accessors/assembly may use Contents/Resources instead.
    for bundle in binary_dir.glob('*.bundle'):
        shutil.copytree(bundle, app / bundle.name)
    run([str(executable), '--check-resources'])
    if len(sys.argv) >= 5:
        run([str(executable), '--transcribe', sys.argv[4], sys.argv[3]] + (['--streaming'] if '--streaming' in sys.argv[5:] else []))
    pin = next(pin for pin in json.loads((consumer / 'Package.resolved').read_text())['pins'] if pin['identity'] == 'parakeet-ane-server')
    if version:
        assert pin['state']['version'] == version
    print(json.dumps({'revision': revision, 'resolvedState': pin['state'], 'consumer': 'passed', 'moduleIsolation': 'passed', 'appResources': 'passed'}))
