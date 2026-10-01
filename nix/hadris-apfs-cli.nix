{ lib, rustPlatform, src }:
rustPlatform.buildRustPackage {
  pname = "hadris-apfs-cli";
  version = "2.4.0";
  inherit src;
  cargoLock.lockFile = src + "/Cargo.lock";
  cargoBuildFlags = [ "-p" "hadris-apfs-cli" ];
  cargoTestFlags = [ "-p" "hadris-apfs" "-p" "hadris-apfs-cli" ];
  postCheck = ''
    cargo check --offline --locked -p hadris-apfs --no-default-features --features alloc,read,sync,tree
  '';
  meta = {
    description = "Read-only APFS image inspector from Hadris PR 68";
    homepage = "https://github.com/hxyulin/hadris/pull/68";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "hadris-apfs";
  };
}
