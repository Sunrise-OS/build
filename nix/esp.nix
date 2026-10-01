{
  lib,
  stdenvNoCC,
  mkesp,
  q1n1,
  kernelcache,
  afdt,
}:
stdenvNoCC.mkDerivation {
  pname = "xnu-esp";
  version = "1";
  dontUnpack = true;
  nativeBuildInputs = [ mkesp ];
  installPhase = ''
    mkdir -p $out
    mkesp ${q1n1}/EFI/BOOT/BOOTAA64.EFI $out/xnu-esp.img \
      ${kernelcache}/boot/kernelcache=KERNEL ${afdt}/AFDT=AFDT
  '';
  meta = {
    license = lib.licenses.unfree;
    hydraPlatforms = [ ];
    platforms = lib.platforms.linux;
  };
}
