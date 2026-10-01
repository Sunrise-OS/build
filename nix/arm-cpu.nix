{
  callPackage,
  repo,
  kext-compiler,
}:
callPackage ./local-kext.nix {
  inherit kext-compiler;
  name = "arm-cpu-kext";
  src = repo + "/kernelcache/drivers";
  sourceFile = "OSSARMCPU.cpp";
  plistFile = "OSSARMCPU-Info.plist";
}
