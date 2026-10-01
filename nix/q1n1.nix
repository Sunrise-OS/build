{
  lib,
  stdenv,
  clang,
  llvm,
  lld,
  src,
  bootArgs ? null,
}:
stdenv.mkDerivation {
  pname = "q1n1-uefi";
  version = "0.1.0";
  inherit src;
  nativeBuildInputs = [
    llvm
    lld
  ];
  postPatch = lib.optionalString (bootArgs != null) ''
    # Upstream currently hard-codes the command line independently of AFDT.
    substituteInPlace platform/uefi/xnu-boot-efi.c \
      --replace-fail ${lib.escapeShellArg (builtins.toJSON "rd=md0 -v serial=3 debug=0x14e keepsyms=1 serial-device-name=uart0")} \
      ${lib.escapeShellArg (builtins.toJSON bootArgs)}
  '';
  dontConfigure = true;
  dontStrip = true;
  enableParallelBuilding = true;
  makeFlags = [
    "-f"
    "platform/uefi/Makefile"
    "CC=${clang.cc}/bin/clang"
    "LD=${lld}/bin/lld-link"
    "LLD=${lld}/bin/ld.lld"
    "OBJCOPY=${llvm}/bin/llvm-objcopy"
  ];
  buildFlags = [ "build/uefi/q1n1.efi" ];
  installPhase = ''
    mkdir -p $out/EFI/BOOT
    cp build/uefi/q1n1.efi $out/EFI/BOOT/BOOTAA64.EFI
  '';
  meta.platforms = lib.platforms.linux;
}
