{
  callPackage,
  repo,
  kext-compiler,
}:
callPackage ./local-kext.nix {
  inherit kext-compiler;
  name = "platform-expert-kext";
  src = repo + "/kernelcache/drivers";
  sourceFile = "OSSPlatformExpert.cpp";
  plistFile = "OSSPlatformExpert-Info.plist";
}
