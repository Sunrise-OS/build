{
  lib,
  rustPlatform,
  src,
}:
rustPlatform.buildRustPackage {
  pname = "mold-macho";
  version = "0.1.0";
  inherit src;
  cargoLock = {
    lockFile = src + "/Cargo.lock";
    outputHashes = {
    };
  };
  cargoBuildFlags = [
    "-p"
    "mold-macho-cli"
  ];
  # Upstream integration tests require a Darwin SDK and external toolchain.
  doCheck = false;
  postInstall = ''
    ln -s mold $out/bin/ld64.mold
  '';
  meta = {
    description = "Mach-O linker from mold-macho PR #35";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
