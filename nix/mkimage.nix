{
  callPackage,
  src,
  makeWrapper,
  clang,
  mold,
  lib,
}:
(callPackage ./rust-host-tool.nix {
  inherit src;
  name = "mkimage";
}).overrideAttrs
  (old: {
    nativeBuildInputs = old.nativeBuildInputs ++ [ makeWrapper ];
    postInstall = ''
      wrapProgram $out/bin/mkimage --prefix PATH : ${
        lib.makeBinPath [
          clang.cc
          mold
        ]
      }
    '';
  })
