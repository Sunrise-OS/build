{
  callPackage,
  repo,
  firmware-src,
  q1n1-src,
  clang,
  llvm,
  lld,
  kernelcache,
  rootfs ? null,
}:
let
  bootArgs = "rd=${if rootfs != null then "disk0" else "md0"} -v serial=3 debug=0x14e keepsyms=1 serial-device-name=uart0 launchdsuffix=release";
  mkesp = callPackage ./mkesp.nix { src = firmware-src; };
  mkimage = callPackage ./mkimage.nix { src = firmware-src; };
  firmware = callPackage ./firmware.nix {
    inherit clang lld mkimage;
    src = firmware-src;
  };
  q1n1 = callPackage ./q1n1.nix {
    inherit clang llvm lld bootArgs;
    src = q1n1-src;
  };
  afdt = callPackage ./afdt.nix {
    inherit repo bootArgs;
    diskRoot = rootfs != null;
  };
  esp = callPackage ./esp.nix {
    inherit
      mkesp
      q1n1
      kernelcache
      afdt
      ;
  };
  boot-xnu = callPackage ./boot-xnu.nix { inherit firmware esp rootfs; };
in
{
  inherit
    mkesp
    mkimage
    firmware
    q1n1
    afdt
    esp
    boot-xnu
    ;
}
