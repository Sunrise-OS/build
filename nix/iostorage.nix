{
  lib,
  stdenv,
  clang,
  kext-compiler,
  mold-macho,
  src,
  repo,
}:
stdenv.mkDerivation {
  pname = "iostorage-kext";
  version = "2.1";
  inherit src;
  nativeBuildInputs = [ kext-compiler ];
  dontConfigure = true;
  dontStrip = true;
  buildPhase = ''
    mkdir -p inc/IOKit/storage
    ln -s "$PWD"/*.h inc/IOKit/storage/
    # The DriverKit-backed device requires iig-generated code. Preserve the
    # existing bring-up shim; this is not DriverKit support.
    sed 's/#include "IOUserBlockStorageDevice_kext.h"/#include "IOUserBlockStorageDevice_shim.h"/' \
      IOBlockStorageDriver.cpp > driver.cpp
    flags=(-I"$PWD/inc" -I"$PWD" -I${repo}/kernelcache/iostorage)
    objs=()
    for f in IOAppleLabelScheme IOApplePartitionScheme IOBlockStorageDevice \
      IOFDiskPartitionScheme IOFilterScheme IOGUIDPartitionScheme IOMediaBSDClient \
      IOMedia IOPartitionScheme IORequest IORequestsPool IOStorage; do
      compile-kext $f.cpp $f.o "''${flags[@]}"
      objs+=($f.o)
    done
    compile-kext driver.cpp driver.o "''${flags[@]}"
    compile-kext ${repo}/kernelcache/iostorage/IOUserBlockStorageDevice_shim.cpp shim.o "''${flags[@]}"
    compile-kext ${repo}/kernelcache/iostorage/IOStorageFamily-mod.cpp module.o "''${flags[@]}"
    ${mold-macho}/bin/ld64.mold -arch arm64 -r "''${objs[@]}" driver.o shim.o module.o -o kext.o
    ${clang.cc}/bin/clang -E -P -x c -DTARGET_OS_OSX=1 -Wno-trigraphs Info.plist -o build-Info.plist
  '';
  installPhase = ''
    mkdir -p $out/include/IOKit/storage
    cp *.h $out/include/IOKit/storage/
    cp kext.o $out/
    cp build-Info.plist $out/Info.plist
  '';
  meta.platforms = lib.platforms.linux;
}
