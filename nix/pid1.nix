{
  lib,
  stdenv,
  clang,
  mold-macho,
  llvm,
  python3,
  repo,
}:
stdenv.mkDerivation {
  pname = "xnu-bringup-pid1";
  version = "1";
  dontUnpack = true;
  dontConfigure = true;
  dontStrip = true;
  nativeBuildInputs = [ python3 ];
  buildPhase = ''
    ${clang.cc}/bin/clang -target arm64-apple-macos15 -mcpu=cortex-a53 -c ${repo}/rootfs/pid1.S -o pid1.o
    ${mold-macho}/bin/ld64.mold -arch arm64 -static -e _start -no_fixup_chains -headerpad 0x400 -adhoc_codesign pid1.o -o launchd
    ${llvm}/bin/llvm-otool -l launchd > load-commands.txt
    grep -q LC_UNIXTHREAD load-commands.txt
    if grep -E 'LC_LOAD_DYLIB|LC_LOAD_DYLINKER' load-commands.txt; then
      echo 'PID 1 must not depend on dyld or libraries' >&2
      exit 1
    fi
  '';
  installPhase = ''
    mkdir -p $out/sbin
    cp launchd $out/sbin/launchd
  '';
  meta = {
    description = "Syscall-only ARM64 Darwin PID 1 for emulator bring-up, not Apple launchd";
    platforms = lib.platforms.linux;
  };
}
