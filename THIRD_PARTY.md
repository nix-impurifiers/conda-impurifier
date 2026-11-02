# Third-party software

Original compiler, channel emitter, launchers, helpers, and tests are MIT licensed.
The shared impurifier engine is MIT licensed; its notice is installed with the
runtime. Generated archives carry the original-code MIT notice under
`info/licenses/`.

Native frontend builds come from the pinned Nixpkgs input: micromamba and
mamba-cpp, plus upstream Conda's Python module. The full Conda CLI is invoked
through `python -m conda`; its pip console entrypoint is intentionally a stub.
The Nixpkgs patches and upstream licenses/notices remain in their native outputs.
No initialization, dependency-policy or package-integrity checks are disabled.

VM provider packages bridge the preinstalled Nix and Python runtimes. The Python
fixture includes the real interpreter with a virtual-environment configuration;
the pip fixture contains the real pip module and metadata. Their original
Python/pip licenses are preserved. These fixtures do not claim to provide a new
production Nix installer or a complete upstream Conda Python distribution.
