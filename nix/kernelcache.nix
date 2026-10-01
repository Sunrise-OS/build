{
  lib,
  stdenv,
  python3,
  mold-macho,
  xnu,
  repo,
  corecrypto,
  pthread,
  iostorage,
  security-stub,
  platform-expert,
  arm-cpu,
  virtio-blk,
  msdosfs,
}:
stdenv.mkDerivation {
  pname = "xnu-kernelcache";
  version = "26.0.0";
  dontUnpack = true;
  dontConfigure = true;
  dontStrip = true;
  nativeBuildInputs = [ python3 ];
  buildPhase = ''
    python3 ${repo}/kernelcache/prelink-kernelcache.py \
      --kernel ${xnu}/boot/kernel.development.qemu --ld ${mold-macho}/bin/ld64.mold --work prelink \
      --kext ${corecrypto}/kext.o ${corecrypto}/Info.plist corecrypto.kext \
      --kext ${security-stub}/kext.o ${security-stub}/Info.plist security_stub.kext \
      --kext ${platform-expert}/kext.o ${platform-expert}/Info.plist OSSPlatformExpert.kext \
      --kext ${arm-cpu}/kext.o ${arm-cpu}/Info.plist OSSARMCPU.kext \
      --kext ${iostorage}/kext.o ${iostorage}/Info.plist IOStorageFamily.kext \
      --kext ${pthread}/kext.o ${pthread}/Info.plist pthread.kext \
      --kext ${virtio-blk}/kext.o ${virtio-blk}/Info.plist IOVirtioBlk.kext \
      --kext ${msdosfs}/kext.o ${msdosfs}/Info.plist msdosfs.kext \
      -o kernelcache
  '';
  installPhase = ''
    mkdir -p $out/boot
    cp kernelcache $out/boot/kernelcache
  '';
  meta = {
    license = lib.licenses.unfree;
    hydraPlatforms = [ ];
    platforms = lib.platforms.linux;
    description = "Prelinked QEMU kernelcache for local bring-up; contains non-redistributable corecrypto";
  };
}
