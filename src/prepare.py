#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Verify installed native Conda files, then prepare their offline Nix closure."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import pwd
import re
import shutil
import subprocess
import sys
import tempfile


def main():
    if os.geteuid() != 0 or len(sys.argv) != 3:
        raise ValueError('use as root: conda-impurifier prepare PREFIX PACKAGE')
    prefix = Path(sys.argv[1]).resolve(strict=True)
    name = sys.argv[2]
    if prefix == Path('/') or not re.fullmatch(r'[a-z0-9][a-z0-9_.-]*', name):
        raise ValueError('invalid native environment or package name')
    records = [json.loads(path.read_text()) for path in (prefix / 'conda-meta').glob('*.json')]
    matches = [record for record in records if record.get('name') == name]
    if len(matches) != 1:
        raise ValueError('package must have exactly one native installed record')
    owned_paths = matches[0]['paths_data']['paths']
    manifest_path = 'share/conda-impurifier/apps/' + name + '/application.json'
    if manifest_path not in {entry['_path'] for entry in owned_paths}:
        raise ValueError('native package does not own its application manifest')
    for entry in owned_paths:
        relative = PurePosixPath(entry['_path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('unsafe native package inventory path')
        path = prefix.joinpath(*relative.parts)
        resolved = path.resolve(strict=True)
        if not resolved.is_relative_to(prefix):
            raise ValueError('application files must remain inside their native prefix')
        expected = entry.get('sha256_in_prefix') or entry['sha256']
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if digest != expected:
            raise ValueError('installed package checksum mismatch: ' + str(relative))
    implementation = prefix / 'share/conda-impurifier/apps' / name
    spec = json.loads((implementation / 'application.json').read_text())
    if not spec['offline'] or not re.fullmatch(r'/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+', spec['installable']):
        raise ValueError('package must carry a valid offline Nix closure')
    owner = implementation.stat().st_uid
    if owner == 0:
        raise ValueError('preparation currently requires a per-user native environment')
    username = pwd.getpwuid(owner).pw_name
    nix_store = shutil.which('nix-store')
    if not nix_store:
        raise ValueError('a working host Nix provider is required')
    with tempfile.TemporaryDirectory(prefix='conda-impurifier-') as temporary:
        subprocess.run([nix_store, '--realise', spec['installable'], '--option', 'substituters', (implementation / 'cache').as_uri(), '--option', 'require-sigs', 'false', '--option', 'builders', '', '--add-root', temporary + '/root', '--indirect'], check=True)
        helper = Path(__file__).with_name('register.py')
        subprocess.run(['runuser', '-u', username, '--', sys.executable, str(helper), str(implementation), nix_store], check=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('conda-impurifier prepare: ' + str(error), file=sys.stderr)
        sys.exit(1)
