{
  availability,
  iig,
  lib,
  mig,
  mold-macho,
  plutil,
  repo,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "xnu-host-tools";
  version = "1";
  dontUnpack = true;
  installPhase = ''
    mkdir -p $out/bin $out/libexec $out/include
    ln -s ${mig}/bin/mig $out/bin/mig
    ln -s ${mig}/bin/cc $out/bin/cc
    ln -s ${mold-macho}/bin/ld64.mold $out/bin/ld64.mold
    ln -s ${mold-macho}/bin/mold $out/bin/mold
    ln -s ${mig}/libexec/migcom $out/libexec/migcom
    ln -s ${iig}/bin/iig $out/bin/iig
    ln -s ${plutil}/bin/plutil $out/bin/plutil
    ln -s ${availability}/libexec/availability.pl $out/libexec/availability.pl
    ln -s ${repo}/nix/mig-include $out/include/mig
  '';
  passthru = {
    inherit
      mig
      iig
      plutil
      availability
      mold-macho
      ;
  };
  meta.platforms = lib.platforms.linux;
}
