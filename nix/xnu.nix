{
  lib,
  stdenv,
  src,
  xnu-build,
}:
stdenv.mkDerivation (
  (builtins.removeAttrs xnu-build [
    "override"
    "overrideDerivation"
  ])
  // {
    pname = "xnu-qemu";
    version = "26.0.0";
    inherit src;
    patches = [ ../patches/xnu-qemu-pan.patch ];
    outputs = [
      "out"
      "headers"
    ];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/boot $headers/BUILD/obj/DEVELOPMENT_ARM64_QEMU/libkern
      install -m644 BUILD/obj/DEVELOPMENT_ARM64_QEMU/kernel.development.qemu $out/boot/kernel.development.qemu
      # Raw exported headers/configuration are required by existing kext builders.
      cp -r BUILD/obj/EXPORT_HDRS $headers/BUILD/obj/
      cp -r BUILD/obj/DEVELOPMENT_ARM64_QEMU/libkern/DEVELOPMENT $headers/BUILD/obj/DEVELOPMENT_ARM64_QEMU/libkern/
      cp -r EXTERNAL_HEADERS $headers/
      make -j$NIX_BUILD_CORES ${lib.escapeShellArgs xnu-build.makeFlags} "''${makeFlagsArray[@]}" installhdrs "DSTROOT=$headers"
      runHook postInstall
    '';
  }
)
