#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Release library roots only after the owning native cache entry disappears."""
import fcntl
import os
from pathlib import Path
import re
import shutil

root = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'conda-impurifier'
for entry in root.iterdir() if root.exists() else []:
    if entry.is_symlink() or not entry.is_dir() or not re.fullmatch(r'[0-9a-f]{64}', entry.name):
        continue
    if entry.stat().st_uid != os.getuid():
        continue
    with (entry / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        location = entry / 'implementation'
        if location.is_symlink() and not location.exists():
            shutil.rmtree(entry)
