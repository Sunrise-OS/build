{
  clang,
  cmake,
  lib,
  llvmPackages,
  ninja,
  src,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "iig";
  version = "unstable-2026-09-30";
  inherit src;
  nativeBuildInputs = [
    cmake
    ninja
    clang
    llvmPackages.libclang
  ];
  cmakeBuildType = "Release";
  ninjaFlags = [ "iig" ];
  installPhase = ''
    mkdir -p $out/bin
    install -m755 $(find . -type f -name iig -perm -u+x | head -1) $out/bin/iig
  '';
  meta.platforms = lib.platforms.linux;
}
