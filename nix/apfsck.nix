{ callPackage, src }:
callPackage ./apfsprogs-tool.nix {
  inherit src;
  tool = "apfsck";
  patches = [ ../patches/apfsck-host-pages.patch ];
}
