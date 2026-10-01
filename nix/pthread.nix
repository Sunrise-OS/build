{
  lib,
  stdenv,
  clang,
  mold-macho,
  xnu,
  src,
}:
stdenv.mkDerivation {
  pname = "pthread-kext";
  version = "539";
  inherit src;
  dontConfigure = true;
  dontStrip = true;
  buildPhase = ''
    k=${xnu.headers}/System/Library/Frameworks/Kernel.framework/Versions/A
    flags=(-target arm64-apple-macos15 -mkernel -ffreestanding -nostdlibinc -fno-builtin -O2
      -mcpu=cortex-a53 -mbranch-protection=bti -std=gnu11 -Wno-int-conversion
      -DKERNEL -DKERNEL_PRIVATE -DXNU_KERNEL_PRIVATE -DMACH_KERNEL_PRIVATE
      -DABSOLUTETIME_SCALAR_TYPE -DNEEDS_SCHED_CALL_T -D__PTHREAD_EXPOSE_INTERNALS__
      -DLP64 -DARM64 -D__ARM64__ -DAPPLE -Iprivate -Iinclude -I.
      -isystem "$k/PrivateHeaders" -isystem "$k/Headers" -isystem ${xnu.headers}/EXTERNAL_HEADERS)
    for f in kern_init kern_support kern_synch; do
      ${clang.cc}/bin/clang "''${flags[@]}" -c kern/$f.c -o $f.o
    done
    cat > module.c <<'EOF'
    #include <mach/mach_types.h>
    #include <mach/kmod.h>
    extern kern_return_t pthread_start(kmod_info_t *, void *);
    extern kern_return_t pthread_stop(kmod_info_t *, void *);
    KMOD_EXPLICIT_DECL(com.apple.kec.pthread, "1.0.0", pthread_start, pthread_stop)
    EOF
    ${clang.cc}/bin/clang "''${flags[@]}" -c module.c -o module.o
    ${mold-macho}/bin/ld64.mold -arch arm64 -r kern_init.o kern_support.o kern_synch.o module.o -o kext.o
    sed -e 's/\''${EXECUTABLE_NAME}/pthread/; s/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.apple.kec.pthread/; s/\''${PRODUCT_NAME}/pthread/' \
      kern/pthread-Info.plist > Info.plist
  '';
  installPhase = ''
    mkdir -p $out
    cp kext.o Info.plist $out/
  '';
  meta.platforms = lib.platforms.linux;
}
