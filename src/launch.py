#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Realize a Nix application while leaving native Zero Install ownership intact."""
import fcntl
import json
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import shlex
import sys


def main():
    mode = sys.argv.pop(1)
    if mode not in ('run', 'register'):
        raise ValueError('invalid application activation mode')
    implementation = Path(sys.argv.pop(1)).resolve(strict=True)
    spec = json.loads((implementation / 'application.json').read_text())
    state = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'conda-impurifier' / hashlib.sha256(str(implementation).encode()).hexdigest()
    current = (implementation.parent.parent / 'runtime-version').read_text().strip()
    minimum = spec['runtimeVersion']
    if tuple(map(int, current.split('.'))) < tuple(map(int, minimum.split('.'))):
        raise ValueError('native Conda impurifier runtime is too old; upgrade conda-impurifier')
    state.mkdir(parents=True, exist_ok=True)
    with (state / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        location = state / 'implementation'
        if not location.is_symlink():
            location.symlink_to(implementation / 'application.json')
        if mode == 'register' and not Path(spec['installable']).exists():
            return
        command = ['nix-store', '--realise', spec['installable']]
        if spec['offline'] and not Path(spec['installable']).exists():
            command += ['--option', 'substituters', (implementation / 'cache').as_uri(), '--option', 'require-sigs', 'false', '--option', 'builders', '']
        try:
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            if spec['offline'] and os.geteuid() != 0:
                print('Offline import may need root preparation: sudo conda-impurifier prepare ' + shlex.quote(str(implementation.parents[3])) + ' ' + shlex.quote(spec['name']), file=sys.stderr)
            raise
        subprocess.run(['nix-store', '--realise', spec['installable'], '--add-root', str(state / 'nix-root'), '--indirect'], check=True, stdout=subprocess.DEVNULL)
    if mode == 'register':
        return
    executable = spec['installable'] + '/bin/' + spec['program']
    environment = os.environ.copy()
    if spec.get('hardware'):
        module_spec = importlib.util.spec_from_file_location('impurifier_engine', Path(__file__).resolve().parent / 'engine.py')
        engine = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(engine)
        manifest_name = 'app-' + hashlib.sha256(spec['name'].encode()).hexdigest()[:24]
        manifest = engine.validate({'name': manifest_name, 'version': spec['version'], 'priority': 5, 'installable': spec['installable'], 'hardware': spec['hardware']}, 'conda-impurifier')
        # Capture and root a fresh immutable snapshot before starting the app.
        with (state / 'lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            snapshot = engine.hardware_snapshots([manifest], state)[manifest_name]
            key = hashlib.sha256(snapshot.encode()).hexdigest()
            subprocess.run(['nix-store', '--realise', snapshot, '--add-root', str(state / ('library-' + key)), '--indirect'], check=True, stdout=subprocess.DEVNULL)
            environment['LD_LIBRARY_PATH'] = snapshot + (':' + environment['LD_LIBRARY_PATH'] if environment.get('LD_LIBRARY_PATH') else '')
            preload = [str(Path(snapshot) / name) for name in spec['hardware']['preload']]
            if preload:
                environment['LD_PRELOAD'] = ' '.join(preload) + (' ' + environment['LD_PRELOAD'] if environment.get('LD_PRELOAD') else '')
    os.execve(executable, [spec['program'], *sys.argv[1:]], environment)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print('conda-impurifier: ' + str(error), file=sys.stderr)
        sys.exit(1)
