{
  gnused,
  lib,
  python3,
  src,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "availability-pl";
  version = "157.2";
  inherit src;
  nativeBuildInputs = [
    python3
    gnused
  ];
  buildPhase = ''
    mkdir -p obj
    python3 ./availability --av_version 12377.121.6 --preprocess ./availability obj/availability
  '';
  installPhase = ''
    mkdir -p $out/libexec
    install -m755 obj/availability $out/libexec/availability.pl
    patchShebangs --build $out/libexec/availability.pl
  '';
  meta.platforms = lib.platforms.linux;
}
