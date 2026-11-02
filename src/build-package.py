# SPDX-License-Identifier: MIT
"""Emit canonical Conda tar.bz2 artifacts with complete native metadata."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile

payload, output, licensefile, specfile = map(Path, sys.argv[1:])
spec = json.loads(specfile.read_text())
root = Path('root')
shutil.copytree(payload, root, symlinks=True)
root.chmod(0o755)
for directory in root.rglob('*'):
    if directory.is_dir() and not directory.is_symlink():
        directory.chmod(0o755)
if (root / 'info').exists():
    raise ValueError('payload must not supply reserved info metadata')
files = []
paths = []
for path in sorted(root.rglob('*')):
    relative = str(path.relative_to(root))
    if '\n' in relative:
        raise ValueError('invalid native package path')
    if path.is_symlink():
        if not path.is_file():
            raise ValueError('symlinks must identify regular payload files')
        kind = 'softlink'
    elif path.is_file():
        kind = 'hardlink'
    elif path.is_dir():
        continue
    else:
        raise ValueError('unsupported native package entry')
    files.append(relative)
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    paths.append({'_path': relative, 'path_type': kind, 'sha256': digest, 'size_in_bytes': path.stat().st_size})
info = root / 'info'
info.mkdir()
(info / 'licenses').mkdir()
shutil.copyfile(licensefile, info / 'licenses/nix-impurifiers-original-code-MIT.txt')
index = {
    'name': spec['name'], 'version': spec['version'], 'build': spec['build'],
    'build_number': spec['buildNumber'], 'depends': spec['dependencies'],
    'constrains': [], 'subdir': 'linux-64', 'arch': 'x86_64', 'platform': 'linux',
    'license': spec['license'], 'timestamp': spec['timestamp'],
}
(info / 'index.json').write_text(json.dumps(index, sort_keys=True))
(info / 'paths.json').write_text(json.dumps({'paths_version': 1, 'paths': paths}, sort_keys=True))
(info / 'files').write_text(''.join(name + '\n' for name in files))
(info / 'about.json').write_text(json.dumps({'summary': spec['description'], 'license': spec['license']}))
output.mkdir()
target = output / (spec['name'] + '-' + spec['version'] + '-' + spec['build'] + '.tar.bz2')
with tarfile.open(target, 'w:bz2', format=tarfile.PAX_FORMAT) as archive:
    for path in sorted(root.rglob('*')):
        entry = archive.gettarinfo(str(path), str(path.relative_to(root)))
        entry.uid = entry.gid = 0
        entry.uname = entry.gname = ''
        entry.mtime = 1
        if entry.isdir():
            entry.mode = 0o755
        elif entry.isfile():
            entry.mode |= 0o200
        if entry.isfile():
            with path.open('rb') as stream:
                archive.addfile(entry, stream)
        else:
            archive.addfile(entry)
