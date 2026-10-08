# Shared settings for the XNU kernel and headers outputs.
{
  lib,
  stdenv,
  clang,
  llvm,
  compiler-rt-src,
  host-tools,
  mold-macho,
  bison,
  flex,
  perl,
  python3,
  tcsh,
  unifdef,
  git,
  gnumake,
  coreutils,
  gnused,
  gnugrep,
  findutils,
  file,
  which,
  bash,
  writeShellScriptBin,
  libdispatch-src,
  repo,
}:
let
  host-clang = writeShellScriptBin "xnu-host-clang" ''
    exec ${clang}/bin/clang -fsigned-char "$@"
  '';
  ar-darwin = writeShellScriptBin "ar-darwin" ''
    exec ${llvm}/bin/llvm-ar --format=darwin "$@"
  '';
in
{
  nativeBuildInputs = [
    clang
    llvm
    host-tools
    mold-macho
    ar-darwin
    bison
    flex
    perl
    python3
    tcsh
    unifdef
    git
    gnumake
    coreutils
    gnused
    gnugrep
    findutils
    file
    which
    bash
  ];
  # Nix's host compiler wrapper must not add Linux headers/link flags to Mach-O builds.
  # Host utilities still use the wrapped compiler to locate the host libc.
  makeFlags = [
    "CC=${clang.cc}/bin/clang"
    "CXX=${clang.cc}/bin/clang++"
    "HOST_CC=${host-clang}/bin/xnu-host-clang"
    "HOST_CXX=${clang}/bin/clang++"
    "MIGCC=${clang.cc}/bin/clang"
    "AR=ar-darwin"
    "STRIP=${llvm}/bin/llvm-strip"
    "NM=${llvm}/bin/llvm-nm"
    "DSYMUTIL=${llvm}/bin/dsymutil"
    "OTOOL=${llvm}/bin/llvm-otool"
    "MIG=${host-tools}/bin/mig"
    "MIGCOM=${host-tools}/libexec/migcom"
    "IIG=${host-tools}/bin/iig"
    "DO_CTFMERGE=0"
    "HOST_OS=Linux"
    "ARCH_CONFIGS=ARM64"
    "KERNEL_CONFIGS=DEVELOPMENT"
    "MACHINE_CONFIGS=QEMU"
    "BUILD_LTO=0"
    "USE_LTO=0"
    "PRE_LTO=0"
    "BUILD_WERROR=0"
    "COMPILER_RT_PROFILE_SOURCE=${compiler-rt-src}"
  ];
  dontConfigure = true;
  dontStrip = true;
  enableParallelBuilding = true;
  postPatch = ''
    patchShebangs .
    # Explicit /bin/echo is not available in the sandbox.
    substituteInPlace SETUP/newvers --replace-fail /bin/echo '${coreutils}/bin/echo'
    mkdir -p devroot/usr/local/libexec
    ln -s ${host-tools}/libexec/availability.pl devroot/usr/local/libexec/availability.pl
    # Restore the upstream kernel Firehose implementation removed from this XNU fork.
    cp ${libdispatch-src}/src/firehose/firehose_buffer.c libkern/firehose/
    cp ${libdispatch-src}/src/firehose/firehose_buffer_internal.h libkern/firehose/
    cp ${libdispatch-src}/src/firehose/firehose_inline_internal.h libkern/firehose/
    mkdir -p libkern/firehose/internal
    cp ${libdispatch-src}/src/shims/atomic.h libkern/firehose/internal/atomic.h
    cp ${libdispatch-src}/os/firehose_buffer_private.h libkern/os/
    mkdir -p EXTERNAL_HEADERS/os
    cp ${libdispatch-src}/os/firehose_buffer_private.h EXTERNAL_HEADERS/os/
    chmod u+w libkern/firehose/firehose_buffer.c libkern/os/firehose_buffer_private.h EXTERNAL_HEADERS/os/firehose_buffer_private.h
    python3 ${repo}/patches/restore-firehose-api.py
    chmod u+w libkern/os/log.c
    echo '#include "../firehose/firehose_buffer.c"' >> libkern/os/log.c
    # Enable the SPI only for the QEMU machine configuration.
    substituteInPlace makedefs/MakeInc.def --replace-fail \
      'MACHINE_FLAGS_ARM64_QEMU = -DARM64_BOARD_CONFIG_QEMU -mcpu=cortex-a53' \
      'MACHINE_FLAGS_ARM64_QEMU = -DARM64_BOARD_CONFIG_QEMU -DOS_FIREHOSE_SPI=1 -mcpu=cortex-a76'
  '';
  preBuild = ''
    makeFlagsArray+=("FAKEROOT_DIR=$PWD/devroot" "SDKROOT=$PWD/devroot")
    makeFlagsArray+=("LDFLAGS_KERNEL_RELEASE=-Wl,-no_fixup_chains -Wl,-read_only_relocs,suppress" "LDFLAGS_KERNEL_DEVELOPMENT=-Wl,-no_fixup_chains -Wl,-read_only_relocs,suppress")
    export SOURCE_DATE_EPOCH=1
  '';
  meta = {
    description = "XNU ARM64 DEVELOPMENT kernel for QEMU";
    platforms = lib.platforms.linux;
  };
}
