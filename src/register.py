# SPDX-License-Identifier: MIT
"""Register the prepared closure after privileges have been dropped."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

implementation = Path(sys.argv[1]).resolve(strict=True)
spec = json.loads((implementation / 'application.json').read_text())
state = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'conda-impurifier' / hashlib.sha256(str(implementation).encode()).hexdigest()
state.mkdir(parents=True, exist_ok=True)
with (state / 'lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    location = state / 'implementation'
    if not location.is_symlink():
        location.symlink_to(implementation / 'application.json')
    subprocess.run([sys.argv[2], '--realise', spec['installable'], '--add-root', str(state / 'nix-root'), '--indirect'], check=True)
