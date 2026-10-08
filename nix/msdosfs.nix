{
  lib,
  stdenv,
  kext-compiler,
  mold-macho,
  src,
  repo,
}:
stdenv.mkDerivation {
  pname = "msdosfs-kext";
  version = "1.0.0";
  inherit src;
  nativeBuildInputs = [ kext-compiler ];
  dontConfigure = true;
  dontStrip = true;
  patches = [ ../patches/msdosfs-qemu-root.patch ];
  buildPhase = ''
    mkdir objects
    for source in msdosfs.kextproj/msdosfs.kmodproj/*.c; do
      compile-kext "$source" "objects/$(basename "$source" .c).o" -DMSDOSFS_AUTO_UNLOAD=0 -DDEBUG=0
    done
    compile-kext ${repo}/kernelcache/msdosfs/module.c objects/module.o
    compile-kext ${repo}/kernelcache/msdosfs/Bootstrap.cpp objects/bootstrap.o
    ${mold-macho}/bin/ld64.mold -arch arm64 -r objects/*.o -o kext.o
  '';
  installPhase = ''
    mkdir -p $out
    cp kext.o $out/kext.o
    cp ${repo}/kernelcache/msdosfs/Info.plist $out/Info.plist
  '';
  meta = {
    license = lib.licenses.apple-psl20;
    platforms = lib.platforms.linux;
    description = "Apple msdosfs with read-only root mounting for QEMU bring-up";
  };
}
