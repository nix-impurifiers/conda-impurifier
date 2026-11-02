# SPDX-License-Identifier: MIT
{
  pkgs,
  coreSrc,
  sourceInfo ? { },
}:
let
  inherit (pkgs) lib;
  core = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "conda-impurifier";
    sourceInfo.lastModified = lib.max (
      if builtins.isAttrs coreSrc then coreSrc.lastModified or 0 else 0
    ) (if builtins.isAttrs sourceInfo then sourceInfo.lastModified or 0 else 0);
  };
  sourceEpoch = lib.toInt (lib.last (lib.splitString "." core.runtimeVersion));
  helpers = pkgs.runCommand "conda-impurifier-helpers" { } ''
    mkdir -p $out
    cp ${../src/prepare.py} $out/prepare.py
    cp ${../src/register.py} $out/register.py
    cp ${../src/prune.py} $out/prune.py
  '';
  package = pkgs.writeShellApplication {
    name = "conda-impurifier";
    runtimeInputs = [
      pkgs.python3
      pkgs.nix
      pkgs.util-linux
    ];
    text = ''
      if [ "$#" -eq 0 ]; then
        echo 'usage: conda-impurifier prepare PREFIX PACKAGE | prune' >&2
        exit 2
      fi
      impurifier_action=$1
      shift
      case "$impurifier_action" in
        prepare) exec python3 ${helpers}/prepare.py "$@" ;;
        prune) [ "$#" -eq 0 ]; exec python3 ${helpers}/prune.py ;;
        *) echo 'usage: conda-impurifier prepare PREFIX PACKAGE | prune' >&2; exit 2 ;;
      esac
    '';
  };
  tools = import ./tools.nix { inherit pkgs; };
  buildPackage =
    {
      name,
      version,
      payload,
      build ? "0",
      buildNumber ? 0,
      dependencies ? [ ],
      license ? "MIT",
      timestamp ? sourceEpoch * 1000,
      description ? "Nix projected application",
    }:
    assert lib.assertMsg (
      builtins.match "[a-z0-9][a-z0-9_.-]*" name != null
      && builtins.match "[A-Za-z0-9_.+!]+" version != null
      && builtins.match "[A-Za-z0-9_.]+" build != null
    ) "invalid Conda package identity";
    pkgs.runCommand "${name}-${version}-${build}-conda"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
        passthru = { inherit name version build; };
      }
      ''
        python3 ${../src/build-package.py} ${payload} "$out" ${../LICENSE} ${
          pkgs.writeText "conda-package.json" (
            builtins.toJSON {
              inherit
                name
                version
                build
                buildNumber
                dependencies
                license
                description
                timestamp
                ;
            }
          )
        }
      '';
  makeChannel =
    { packages }:
    pkgs.runCommand "impurifier-conda-channel"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        python3 ${../src/channel.py} "$out" ${lib.escapeShellArgs (map toString packages)}
      '';
  makeRuntimePackage =
    {
      nixDependency ? "nix >=2.0",
      pythonDependency ? "python >=3.8",
      version ? core.runtimeVersion,
    }:
    buildPackage {
      name = "conda-impurifier";
      inherit version;
      dependencies = [
        nixDependency
        pythonDependency
      ];
      payload = pkgs.runCommand "conda-runtime" { } ''
        mkdir -p $out/share/conda-impurifier/runtime
        cp ${../src/launch.py} $out/share/conda-impurifier/runtime/launch.py
        cp ${../src/unlink.py} $out/share/conda-impurifier/runtime/unlink.py
        cp ${coreSrc}/src/engine.py $out/share/conda-impurifier/runtime/engine.py
        cp ${../LICENSE} $out/share/conda-impurifier/LICENSE
        echo '${version}' > $out/share/conda-impurifier/runtime-version
      '';
    };
  makePackageArtifact =
    {
      pkg,
      name ? pkg.pname,
      version ? pkg.version,
      program ? pkg.meta.mainProgram or pkg.pname,
      entrypoint ? program,
      description ? pkg.meta.description or "Nix projected ${name}",
      offline ? false,
      dependencies ? [ ],
      hardware ? null,
      buildNumber ? sourceEpoch,
      license ? null,
    }:
    assert lib.assertMsg (
      name != "conda-impurifier" && builtins.match "[a-z0-9][a-z0-9_.-]*" name != null
    ) "invalid or reserved native application name";
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9_.+-]+" program != null
      && !(lib.elem program [
        "."
        ".."
      ])
    ) "invalid Nix application program";
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9_.+-]+" entrypoint != null
      && !(lib.elem entrypoint [
        "."
        ".."
      ])
    ) "invalid native application entrypoint";
    assert lib.assertMsg (
      hardware == null || lib.elem program (hardware.programs or [ ])
    ) "hardware programs must include the selected application program";
    let
      applicationLicense =
        if license != null then
          license
        else
          lib.concatStringsSep " AND " (
            lib.unique (
              [ "MIT" ]
              ++ map (
                value: if builtins.isAttrs value then value.spdxId or "LicenseRef-Unknown" else "LicenseRef-Unknown"
              ) (lib.toList (pkg.meta.license or [ ]))
            )
          );
      spec = {
        inherit
          name
          version
          program
          offline
          ;
        runtimeVersion = core.runtimeVersion;
        installable = toString pkg;
        hardware = if hardware == null then null else { preload = [ ]; } // hardware;
      };
      wrapper = ''
        #!/bin/sh
        conda_prefix=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
        export PATH="$conda_prefix/bin:$PATH"
        exec "$conda_prefix/bin/python3" "$conda_prefix/share/conda-impurifier/runtime/launch.py" run "$conda_prefix/share/conda-impurifier/apps/${name}" "$@"
      '';
      link = ''
        #!/bin/bash
        export PATH="$PREFIX/bin:$PATH"
        "$PREFIX/bin/python3" "$PREFIX/share/conda-impurifier/runtime/launch.py" register "$PREFIX/share/conda-impurifier/apps/${name}"
      '';
      unlink = ''
        #!/bin/bash
        "$PREFIX/bin/python3" "$PREFIX/share/conda-impurifier/runtime/unlink.py" "$PREFIX/share/conda-impurifier/apps/${name}"
      '';
      identity = builtins.unsafeDiscardStringContext (
        builtins.substring 0 16 (
          builtins.hashString "sha256" (
            builtins.toJSON {
              inherit
                spec
                dependencies
                applicationLicense
                entrypoint
                ;
              emitter = if builtins.isAttrs sourceInfo then toString (sourceInfo.outPath or "") else "";
              engine = toString coreSrc;
            }
          )
        )
      );
    in
    buildPackage {
      inherit
        name
        version
        buildNumber
        description
        ;
      license = applicationLicense;
      build = "${if offline then "offline" else "net"}_${identity}_${toString buildNumber}";
      dependencies = [ "conda-impurifier >=${core.runtimeVersion}" ] ++ dependencies;
      payload = pkgs.runCommand "conda-application" { } ''
        mkdir -p $out/bin $out/share/conda-impurifier/apps/${name}
        cp ${pkgs.writeText "application.json" (builtins.toJSON spec)} $out/share/conda-impurifier/apps/${name}/application.json
        install -m755 ${pkgs.writeText "entry" wrapper} $out/bin/${entrypoint}
        install -m755 ${pkgs.writeText "post-link" link} $out/bin/.${name}-post-link.sh
        install -m755 ${pkgs.writeText "pre-unlink" unlink} $out/bin/.${name}-pre-unlink.sh
        ${lib.optionalString offline "cp -r ${core.offlineCache pkg} $out/share/conda-impurifier/apps/${name}/cache"}
      '';
    };
in
{
  inherit
    tools
    package
    buildPackage
    makeChannel
    makeRuntimePackage
    makePackageArtifact
    ;
  runtimePackage = makeRuntimePackage { };
  makeNetPackage = args: makePackageArtifact (args // { offline = false; });
  makeOfflinePackage = args: makePackageArtifact (args // { offline = true; });
  makePackage = args: {
    net = makePackageArtifact (args // { offline = false; });
    offline = makePackageArtifact (args // { offline = true; });
  };
}
