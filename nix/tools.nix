# SPDX-License-Identifier: MIT
{ pkgs }:
let
  condaPython = pkgs.python3.withPackages (ps: [ ps.conda ]);
  conda = pkgs.runCommand "native-conda-cli" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    mkdir -p $out/bin
    # Upstream's module is the full CLI; its pip console entry is a stub.
    makeWrapper ${condaPython}/bin/python3 $out/bin/conda \
      --add-flags '-m conda' --set CONDA_EXE $out/bin/conda
  '';
  package = pkgs.symlinkJoin {
    name = "native-conda-frontends";
    paths = [
      pkgs.micromamba
      pkgs.mamba-cpp
      conda
    ];
  };
in
{
  inherit package conda;
}
