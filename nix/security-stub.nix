{
  callPackage,
  repo,
  kext-compiler,
}:
callPackage ./local-kext.nix {
  inherit kext-compiler;
  name = "security-stub-kext";
  src = repo + "/kernelcache/stubs";
  sourceFile = "security_stub.c";
  plistFile = "security_stub-Info.plist";
}
