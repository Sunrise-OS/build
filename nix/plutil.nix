{
  clang,
  cmake,
  lib,
  llvmPackages,
  ninja,
  pkg-config,
  src,
  stdenv,
  zlib,
  libpng,
  libxml2,
}:
stdenv.mkDerivation {
  pname = "xcbuild-plutil";
  version = "unstable-2026-09-30";
  inherit src;
  nativeBuildInputs = [
    cmake
    ninja
    clang
    llvmPackages.libclang
    pkg-config
  ];
  buildInputs = [
    zlib
    libpng
    libxml2
  ];
  cmakeBuildType = "Release";
  cmakeFlags = [ "-DBUILD_TESTING=OFF" ];
  ninjaFlags = [ "plutil" ];
  installPhase = ''
    mkdir -p $out/bin
    install -m755 $(find . -type f -name plutil -perm -u+x | head -1) $out/bin/plutil
  '';
  meta.platforms = lib.platforms.linux;
}
