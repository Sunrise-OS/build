{ callPackage, src }:
callPackage ./apfsprogs-tool.nix {
  inherit src;
  tool = "mkapfs";
  patches = [ ../patches/mkapfs-reproducible.patch ];
}
