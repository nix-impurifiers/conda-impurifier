# SPDX-License-Identifier: MIT
{ pkgs, impurifier }:
let
  payload =
    version:
    pkgs.pkgsStatic.runCommandCC "native-proof-${version}" { } ''
      mkdir -p $out/bin
      cat > proof.c <<'C'
      #include <stdio.h>
      int main(void) { puts("native-proof-${version}"); return 0; }
      C
      $CC -static -Os proof.c -o $out/bin/native-proof
    '';
  application =
    version:
    impurifier.makeNativePackage {
      name = "native-proof";
      inherit version;
      payload = payload version;
      license = "MIT";
    };
  channel = impurifier.makeChannel {
    packages = [
      (application "1")
      (application "2")
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "conda-native-payload-independent-prefixes";
  requiredFeatures.kvm = false;
  requiredFeatures.devnet = false;
  nodes.machine = { lib, ... }: {
    virtualisation.memorySize = 1536;
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    environment.systemPackages = [ pkgs.micromamba ];
    users.users.consumer.isNormalUser = true;
  };
  testScript = ''
    import shlex
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /home/consumer/target; cp -r ${channel} /home/consumer/channel; chown -R consumer:users /home/consumer")
    def native(prefix, action):
        command = "MAMBA_ROOT_PREFIX=/home/consumer/mamba-root micromamba " + action + " --offline --yes --prefix /home/consumer/target/" + prefix + (" --override-channels -c file:///home/consumer/channel" if not action.startswith("remove") else "")
        machine.succeed("su - consumer -c " + shlex.quote(command))
    with subtest("two native prefixes run in a root with no Nix files"):
        native("a", "create native-proof=1")
        native("b", "create native-proof=1")
        machine.succeed("chroot /home/consumer/target /a/bin/native-proof | grep native-proof-1")
        machine.succeed("chroot /home/consumer/target /b/bin/native-proof | grep native-proof-1")
        machine.succeed("test ! -e /home/consumer/target/nix")
    with subtest("upgrade and removal remain local to their environment"):
        native("a", "install native-proof=2")
        machine.succeed("chroot /home/consumer/target /a/bin/native-proof | grep native-proof-2")
        machine.succeed("chroot /home/consumer/target /b/bin/native-proof | grep native-proof-1")
        native("a", "remove native-proof")
        machine.fail("test -e /home/consumer/target/a/bin/native-proof")
        machine.succeed("chroot /home/consumer/target /b/bin/native-proof | grep native-proof-1")
        native("b", "remove native-proof")
        machine.fail("test -e /home/consumer/target/b/bin/native-proof")
        machine.succeed("test ! -e /home/consumer/target/nix")
  '';
}
