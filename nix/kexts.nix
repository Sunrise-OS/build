{
  callPackage,
  repo,
  xnu,
  xnu-src,
  corecrypto-src,
  pthread-src,
  iostorage-src,
  msdosfs-src,
  clang,
  llvm,
  mold-macho,
}:
let
  kext-compiler = callPackage ./kext-compiler.nix { inherit clang xnu xnu-src; };
  corecrypto = callPackage ./corecrypto.nix {
    inherit
      clang
      llvm
      mold-macho
      xnu
      repo
      ;
    src = corecrypto-src;
  };
  pthread = callPackage ./pthread.nix {
    inherit clang mold-macho xnu;
    src = pthread-src;
  };
  iostorage = callPackage ./iostorage.nix {
    inherit
      clang
      kext-compiler
      mold-macho
      repo
      ;
    src = iostorage-src;
  };
  msdosfs = callPackage ./msdosfs.nix {
    inherit repo kext-compiler mold-macho;
    src = msdosfs-src;
  };
  security-stub = callPackage ./security-stub.nix { inherit repo kext-compiler; };
  platform-expert = callPackage ./platform-expert.nix { inherit repo kext-compiler; };
  arm-cpu = callPackage ./arm-cpu.nix { inherit repo kext-compiler; };
  virtio-blk = callPackage ./virtio-blk.nix { inherit repo kext-compiler iostorage; };
  kernelcache = callPackage ./kernelcache.nix {
    inherit
      repo
      xnu
      mold-macho
      corecrypto
      pthread
      iostorage
      security-stub
      platform-expert
      arm-cpu
      virtio-blk
      msdosfs
      ;
  };
in
{
  inherit
    corecrypto
    pthread
    iostorage
    security-stub
    platform-expert
    arm-cpu
    virtio-blk
    kernelcache
    msdosfs
    ;
}
