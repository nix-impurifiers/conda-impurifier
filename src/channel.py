# SPDX-License-Identifier: MIT
"""Index artifacts into the native platform/noarch channel layout."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tarfile

output = Path(sys.argv[1])
records = {}
for source in map(Path, sys.argv[2:]):
    for artifact in source.glob('*.tar.bz2'):
        with tarfile.open(artifact) as archive:
            index = json.load(archive.extractfile('info/index.json'))
        destination = output / index['subdir'] / artifact.name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            raise ValueError('duplicate native package filename')
        shutil.copyfile(artifact, destination)
        with artifact.open('rb') as stream:
            sha256 = hashlib.file_digest(stream, 'sha256').hexdigest()
        with artifact.open('rb') as stream:
            md5 = hashlib.file_digest(stream, 'md5').hexdigest()
        records[artifact.name] = index | {'sha256': sha256, 'md5': md5, 'size': artifact.stat().st_size}
for subdir in ('linux-64', 'noarch'):
    directory = output / subdir
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'repodata.json').write_text(json.dumps({'repodata_version': 1, 'info': {'subdir': subdir}, 'packages': records if subdir == 'linux-64' else {}, 'packages.conda': {}, 'removed': []}, sort_keys=True))
