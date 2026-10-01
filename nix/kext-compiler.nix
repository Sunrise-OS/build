{
  writeShellScriptBin,
  clang,
  xnu,
  xnu-src,
}:
writeShellScriptBin "compile-kext" ''
  set -euo pipefail
  src=$1; obj=$2; shift 2
  flags=()
  for d in ${xnu.headers}/BUILD/obj/EXPORT_HDRS/*/; do flags+=("-I$d"); done
  case $src in
    *.cpp) flags+=(-std=gnu++20 -fapple-kext -fno-exceptions -fno-rtti
      -fno-use-cxa-atexit -fno-c++-static-destructors);;
  esac
  exec ${clang.cc}/bin/clang -target arm64-apple-macos15 -mkernel -ffreestanding \
    -nostdlibinc -fno-builtin -O2 -mcpu=cortex-a53 -mbranch-protection=bti \
    -DKERNEL -DKERNEL_PRIVATE -DPRIVATE -DXNU_KERNEL_PRIVATE -DLP64 -DARM64 \
    -D__ARM64__ -DARM64_BOARD_CONFIG_QEMU -DXNU_TARGET_OS_OSX -DIOKITCPP -DAPPLE \
    "''${flags[@]}" -I${xnu.headers}/BUILD/obj/DEVELOPMENT_ARM64_QEMU/libkern/DEVELOPMENT \
    -I${xnu.headers}/EXTERNAL_HEADERS -idirafter ${xnu-src}/iokit \
    -idirafter ${xnu-src}/libkern "$@" -c "$src" -o "$obj"
''
