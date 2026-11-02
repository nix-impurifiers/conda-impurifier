# conda-impurifier

Build native Conda packages for Nix applications, with per-environment launchers,
Nix GC roots, and explicit host-library capture. The same package/channel format
works with micromamba, mamba, and Conda's libmamba and classic solvers.

```nix
let
  impurifier = inputs.conda-impurifier.lib.conda-impurifier { inherit pkgs; };
in impurifier.makePackage { pkg = pkgs.hello; }
```

`makePackage` returns `net` and `offline`; `makeNetPackage` and
`makeOfflinePackage` select one. `makeChannel { packages = [ ... ]; }` emits a
native `linux-64` channel plus the required noarch index. The current target is
x86_64 Linux. Publish the runtime from `makeRuntimePackage` alongside application
packages and provide its native Nix/Python dependencies in accessible channels.

```sh
micromamba install -p "$environment" -c "file://$channel" 'hello=2.12.3=offline_*'
"$environment/bin/hello"
```

Build strings include transport, content identity, and a build number. The
build number defaults to the backend/engine source epoch; packagers can override
`buildNumber` for their own release sequence. Nix's selected main program keeps
its normal command name. `program` selects a Nix binary; `entrypoint` optionally
renames its native environment command. Additional `dependencies` use native
Conda MatchSpec strings. Native dependency solving and package ownership remain
with the selected frontend.

The runtime defaults to `nix >=2.0` and `python >=3.8` dependencies.
`makeRuntimePackage { nixDependency = "my-nix-provider >=2"; ... }` can name a
provider supplied by the packager. A working Nix store/provider is required;
installing Nix and configuring its daemon remain deferred work.

Packages link native application intent first. Existing Nix outputs are rooted
during the native post-link hook; other outputs are realized lazily at launch.
Net applications use the host's configured trusted Nix caches. An untrusted
daemon client cannot import the unsigned bundled offline cache. For that case,
install the trusted helper exported as this flake's default package and prepare
the installed package explicitly:

```sh
sudo "$(command -v conda-impurifier)" prepare "$environment" hello
"$environment/bin/hello"
```

Preparation checks the native installed file inventory and hashes before
importing the closure. It registers roots after dropping privileges to the
prefix owner. It executes no prefix/application code as root and changes no
daemon trust settings. The helper currently targets per-user environments.

Native pre-unlink hooks release that environment application's roots, including
a transport/version replacement. `conda-impurifier prune` also releases roots
whose native application manifest has disappeared. Native package caches may
retain the original artifacts after removal; those archives do not themselves
retain the imported Nix outputs.

`hardware` accepts an explicit library/program/preload mapping. Each launch
captures the current host DSOs as immutable, user-rooted Nix objects. Global
accounts, host configuration, system services, and a shared system profile are
outside this per-environment activation contract. No GPU kernel ABI guarantee is
implied.

Conda's default libmamba solver uses cached channel metadata in `--offline` mode,
even for a local channel. A native local-only `conda search --override-channels
-c file://... PACKAGE` refresh prepares that cache. The tests keep native Python/
pip policy enabled and exercise all four frontend/solver combinations in QEMU.

Original code is MIT licensed. Native application license metadata derives from
its Nix package and can be overridden with `license`; third-party notices are
preserved. See [THIRD_PARTY.md](THIRD_PARTY.md).
