{
  lib,
  stdenv,
  python3,
  clang,
  llvm,
  mold-macho,
  xnu,
  src,
  repo,
}:
stdenv.mkDerivation {
  pname = "corecrypto-kext";
  version = "26.0";
  inherit src;
  nativeBuildInputs = [
    python3
    llvm
  ];
  dontConfigure = true;
  dontStrip = true;
  buildPhase = ''
    python3 ${repo}/kernelcache/build-corecrypto.py --source "$PWD" \
      --source-revision ${src.rev} --xnu ${xnu.headers} \
      --kernel ${xnu}/boot/kernel.development.qemu --output "$PWD/build" \
      --clang ${clang.cc}/bin/clang --ld ${mold-macho}/bin/ld64.mold \
      --nm ${llvm}/bin/llvm-nm --otool ${llvm}/bin/llvm-otool -j$NIX_BUILD_CORES
  '';
  installPhase = ''
    mkdir -p $out
    cp build/corecrypto.o $out/kext.o
    cp corecrypto_kext/corecrypto_kext-Info.plist $out/Info.plist
    cp build/manifest.json $out/
  '';
  meta = {
    license = lib.licenses.unfree;
    hydraPlatforms = [ ];
    platforms = lib.platforms.linux;
    description = "Corecrypto kext for local emulator bring-up; do not redistribute";
  };
}
