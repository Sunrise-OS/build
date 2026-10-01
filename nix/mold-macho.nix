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
      "mimalloc-0.1.52" = "sha256-IF7/1rS0Pazst3rll691hhbB4QZkLHVAr7nv8Uqaf1s=";
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
