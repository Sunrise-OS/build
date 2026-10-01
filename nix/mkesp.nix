{ callPackage, src }:
callPackage ./rust-host-tool.nix {
  inherit src;
  name = "mkesp";
}
