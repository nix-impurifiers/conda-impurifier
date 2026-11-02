# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  tools,
  coreSrc,
}:
let
  marker = impurifier.buildPackage {
    name = "native-marker";
    version = "1";
    payload = pkgs.runCommand "conda-native-marker" { } ''
      mkdir -p $out/share/conda-vm $out/bin
      echo native > $out/share/conda-vm/marker
      cat > $out/bin/.native-marker-post-link.sh <<'SCRIPT'
      #!/bin/bash
      echo installed > "$PREFIX/share/conda-vm/installed"
      SCRIPT
      cat > $out/bin/.native-marker-pre-unlink.sh <<'SCRIPT'
      #!/bin/bash
      echo removed > "$PREFIX/share/conda-vm/removed"
      SCRIPT
      chmod 755 $out/bin/.*.sh
    '';
  };
  tool =
    version:
    pkgs.runCommand "conda-tool-${version}"
      {
        pname = "conda-tool";
        meta.license = pkgs.lib.licenses.mit;
        inherit version;
      }
      ''
        mkdir -p $out/bin
        printf '#!${pkgs.busybox}/bin/sh\necho ${version}\n' > $out/bin/conda-tool
        chmod 755 $out/bin/conda-tool
      '';
  app =
    offline: version:
    impurifier.makePackageArtifact {
      pkg = tool version;
      inherit offline;
    };
  provider =
    name: version: executable: target:
    impurifier.buildPackage {
      inherit name version;
      payload = pkgs.runCommand "${name}-provider-fixture" { } ''
        mkdir -p $out/bin
        printf '#!/bin/sh\nexec ${target} "$@"\n' > $out/bin/${executable}
        chmod 755 $out/bin/${executable}
      '';
    };
  fixture = import (coreSrc + "/tests/hardware-fixture.nix") { inherit pkgs; };
  hardware = impurifier.makeOfflinePackage {
    pkg = fixture.tool;
    name = "hardware_tool";
    inherit (fixture) hardware;
  };
  oldRuntime = impurifier.makeRuntimePackage { version = "0.1"; };
  pythonProvider = impurifier.buildPackage {
    name = "python";
    version = pkgs.python3.version;
    license = "PSF-2.0";
    payload = pkgs.runCommand "native-python-provider-fixture" { } ''
      mkdir -p $out/bin $out/share/licenses/python
      cp -L ${pkgs.python3}/bin/python3 $out/bin/python
      ln -s python $out/bin/python3
      printf 'home = ${pkgs.python3}/bin\ninclude-system-site-packages = false\nversion = ${pkgs.python3.version}\n' > $out/pyvenv.cfg
      cp ${pkgs.python3}/lib/python${pkgs.python3.pythonVersion}/LICENSE.txt $out/share/licenses/python/LICENSE.txt
    '';
  };
  pipProvider = impurifier.buildPackage {
    name = "pip";
    version = pkgs.python3Packages.pip.version;
    dependencies = [ "python >=3.8" ];
    payload = pkgs.runCommand "native-pip-provider-fixture" { } ''
      mkdir -p $out/bin $out/${pkgs.python3.sitePackages}
      cp -r ${pkgs.python3Packages.pip}/${pkgs.python3.sitePackages}/. $out/${pkgs.python3.sitePackages}/
      cat > $out/bin/pip <<'SCRIPT'
      #!/bin/sh
      exec "$(dirname "$0")/python" -m pip "$@"
      SCRIPT
      chmod 755 $out/bin/pip
    '';
  };
  channel = impurifier.makeChannel {
    packages = [
      marker
      (provider "nix" pkgs.nix.version "nix-store" "${pkgs.nix}/bin/nix-store")
      pythonProvider
      pipProvider
      impurifier.runtimePackage
      oldRuntime
      hardware
      (app false "1")
      (app true "1")
      (app true "2")
    ];
  };
in
{
  native-package = marker;
  native-vm = pkgs.testers.runNixOSTest {
    name = "conda-native-contract";
    requiredFeatures = {
      kvm = false;
      devnet = false;
    };
    nodes.machine = { lib, ... }: {
      virtualisation.qemu.package = lib.mkForce pkgs.qemu;
      virtualisation.qemu.forceAccel = false;
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 8192;
      environment.systemPackages = [
        impurifier.package
        tools.package
        pkgs.bash
        pkgs.nix
      ];
      system.extraDependencies = [
        pkgs.python3
        pkgs.python3Packages.pip
      ];
      nix.settings.substituters = lib.mkForce [ ];
      users.users.consumer = {
        isNormalUser = true;
      };
      systemd.tmpfiles.rules = [ "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash" ];
    };
    testScript = ''
      import shlex
      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.succeed("mkdir -p /root/drivers; cp ${fixture.driver "1"}/usr/lib/libimpurifier-driver.so.1 /root/drivers/1.so; cp ${fixture.driver "2"}/usr/lib/libimpurifier-driver.so.1 /root/drivers/2.so")
      machine.succeed("cp -r ${channel} /home/consumer/channel; chown -R consumer:users /home/consumer/channel")
      for frontend, solver in [("micromamba", None), ("mamba", None), ("conda", "libmamba"), ("conda", "classic")]:
          case = frontend + ("-" + solver if solver else "")
          prefix = "/home/consumer/" + case + "-environment"
          environment = "MAMBA_ROOT_PREFIX=/home/consumer/" + frontend + "-root CONDARC=/dev/null "
          if frontend == "conda":
              refresh = environment + "conda search --override-channels --channel file:///home/consumer/channel native-marker"
              machine.succeed("su - consumer -c " + shlex.quote(refresh) + " > /tmp/conda-refresh.log 2>&1 || { cat /tmp/conda-refresh.log; exit 1; }")
          if solver:
              environment += "CONDA_SOLVER=" + solver + " "
          command = environment + frontend + " create --offline --yes --prefix " + prefix + " --override-channels --channel file:///home/consumer/channel native-marker"
          machine.succeed("su - consumer -c " + shlex.quote(command) + " > /tmp/" + frontend + "-create.log 2>&1 || { cat /tmp/" + frontend + "-create.log; exit 1; }")
          machine.succeed("grep native " + prefix + "/share/conda-vm/marker; grep installed " + prefix + "/share/conda-vm/installed; test -f " + prefix + "/conda-meta/native-marker-1-0.json")
          command = environment + frontend + " remove --offline --yes --prefix " + prefix + " native-marker"
          machine.succeed("su - consumer -c " + shlex.quote(command) + " > /tmp/" + frontend + "-remove.log 2>&1 || { cat /tmp/" + frontend + "-remove.log; exit 1; }")
          machine.succeed("test ! -e " + prefix + "/share/conda-vm/marker; grep removed " + prefix + "/share/conda-vm/removed")
          def native(arguments, expect_success=True):
              command = environment + frontend + " " + arguments + " --offline --yes --prefix " + prefix + " --override-channels --channel file:///home/consumer/channel"
              wrapped = "su - consumer -c " + shlex.quote(command) + " > /tmp/" + frontend + "-transaction.log 2>&1"
              if expect_success:
                  machine.succeed(wrapped + " || { cat /tmp/" + frontend + "-transaction.log; exit 1; }")
              else:
                  machine.fail(wrapped)
          native("install 'conda-tool=1=net_*'")
          machine.succeed("test ! -e ${builtins.unsafeDiscardStringContext (toString (tool "1"))}")
          machine.fail("su - consumer -c " + shlex.quote(prefix + "/bin/conda-tool") + " > /tmp/net-activation.log 2>&1")
          native("install 'conda-tool=1=offline_*'")
          machine.fail("su - consumer -c " + shlex.quote(prefix + "/bin/conda-tool") + " > /tmp/offline-restricted.log 2>&1")
          manifest = prefix + "/share/conda-impurifier/apps/conda-tool/application.json"
          machine.succeed("cp " + manifest + " /tmp/saved-application.json; printf ' ' >> " + manifest)
          machine.fail("conda-impurifier prepare " + shlex.quote(prefix) + " conda-tool > /tmp/corrupt-prefix.log 2>&1")
          machine.succeed("grep 'checksum mismatch' /tmp/corrupt-prefix.log; cp /tmp/saved-application.json " + manifest)
          machine.succeed("conda-impurifier prepare " + shlex.quote(prefix) + " conda-tool")
          machine.succeed("su - consumer -c " + shlex.quote(prefix + "/bin/conda-tool") + " | grep '^1$'")
          assert machine.succeed("su - consumer -c " + shlex.quote(prefix + "/bin/conda-tool")).strip() == "1"
          native("install 'conda-tool=2=offline_*'")
          machine.succeed("conda-impurifier prepare " + shlex.quote(prefix) + " conda-tool")
          machine.succeed("su - consumer -c " + shlex.quote(prefix + "/bin/conda-tool") + " | grep '^2$'")
          native("install /home/consumer/channel/linux-64/conda-impurifier-0.1-0.tar.bz2 --no-deps")
          machine.fail("su - consumer -c " + shlex.quote(prefix + "/bin/conda-tool") + " > /tmp/old-runtime.log 2>&1")
          machine.succeed("grep 'runtime is too old' /tmp/old-runtime.log")
          native("install conda-impurifier=${impurifier.runtimePackage.version}")
          native("install hardware_tool")
          machine.succeed("mkdir -p /usr/lib; cp /root/drivers/1.so /usr/lib/libimpurifier-driver.so.1")
          machine.succeed("conda-impurifier prepare " + shlex.quote(prefix) + " hardware_tool")
          machine.succeed("su - consumer -c " + shlex.quote(prefix + "/bin/hardware-tool") + " | grep '^1$'")
          machine.succeed("cp /root/drivers/2.so /usr/lib/libimpurifier-driver.so.1")
          machine.succeed("su - consumer -c " + shlex.quote(prefix + "/bin/hardware-tool") + " | grep '^2$'")
          machine.succeed("nix-collect-garbage")
          machine.succeed("su - consumer -c " + shlex.quote(prefix + "/bin/conda-tool") + " | grep '^2$'")
          machine.succeed("su - consumer -c " + shlex.quote(prefix + "/bin/hardware-tool") + " | grep '^2$'")
          command = environment + frontend + " remove --offline --yes --prefix " + prefix + " conda-tool hardware_tool"
          machine.succeed("su - consumer -c " + shlex.quote(command) + " > /tmp/" + frontend + "-remove-app.log 2>&1 || { cat /tmp/" + frontend + "-remove-app.log; exit 1; }")
          machine.succeed("test ! -e " + prefix + "/bin/conda-tool; nix-collect-garbage")
          machine.succeed("test ! -e ${builtins.unsafeDiscardStringContext (toString (tool "1"))}; test ! -e ${builtins.unsafeDiscardStringContext (toString (tool "2"))}")

    '';
  };
}
