# Development

`buildPackage` emits native tar.bz2 artifacts with index/files/paths metadata and
streamed checksums. `makeChannel` emits canonical repodata with archive hashes.
High-level packages depend on a separately versioned native runtime and own
ordinary prefix files; roots live in the invoking user's state directory.

Native post-link hooks register already-available outputs without requiring an
unsigned import during a package transaction. Launchers realize missing outputs,
then root them and execute the selected program without contaminating stdout.
Native pre-unlink hooks release the corresponding per-prefix state.

The trusted preparation helper verifies the native installed package record,
path inventory, and file hashes. It imports only Nix data and drops privileges
before registering the lasting user root. Never execute prefix code as root.

The QEMU matrix includes micromamba, mamba, Conda/libmamba, and Conda/classic.
It checks native hooks/records, transport replacement, rootless import rejection,
checksum rejection, explicit offline preparation, runtime gates, host-library
changes, GC retention and release. Keep the channel outside the Nix store before
GC. Python's classic-solver pip dependency must remain enabled.

Nix/Python provider fixture packages use preinstalled host resources and retain
third-party notices. A production Nix installer remains deferred. Signed remote
channels, additional architectures, and shared root-owned environment policy
need separate evidence.
