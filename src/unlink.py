# SPDX-License-Identifier: MIT
"""Release the invoking user's roots for the native unlinked application."""
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import sys

implementation = Path(sys.argv[1]).resolve()
state = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'conda-impurifier' / hashlib.sha256(str(implementation).encode()).hexdigest()
if state.is_dir() and not state.is_symlink() and state.stat().st_uid == os.getuid():
    with (state / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        shutil.rmtree(state)
