{
  callPackage,
  repo,
  kext-compiler,
  iostorage,
}:
callPackage ./local-kext.nix {
  inherit kext-compiler;
  name = "virtio-blk-kext";
  src = repo + "/kernelcache/drivers";
  sourceFile = "IOVirtioBlk.cpp";
  plistFile = "IOVirtioBlk-Info.plist";
  extraFlags = [ "-I${iostorage}/include" ];
}
