{
  callPackage,
  repo,
  xnu-src,
  mig-src,
  iig-src,
  xcbuild-src,
  availability-src,
  mold-macho-src,
}:
let
  mig = callPackage ./mig.nix {
    inherit repo xnu-src;
    src = mig-src;
  };
  iig = callPackage ./iig.nix { src = iig-src; };
  plutil = callPackage ./plutil.nix { src = xcbuild-src; };
  availability = callPackage ./availability.nix { src = availability-src; };
  mold-macho = callPackage ./mold-macho.nix { src = mold-macho-src; };
  host-tools = callPackage ./toolchain.nix {
    inherit
      repo
      mig
      iig
      plutil
      availability
      mold-macho
      ;
  };
in
{
  inherit
    mig
    iig
    plutil
    availability
    mold-macho
    host-tools
    ;
}
