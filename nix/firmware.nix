{
  lib,
  stdenv,
  rustc,
  cargo,
  rustPlatform,
  mold,
  lld,
  clang,
  git,
  src,
  mkimage,
  writeShellScript,
}:
let
  deps = rustPlatform.importCargoLock { lockFile = src + "/Cargo.lock"; };
  rust-src = rustPlatform.rustLibSrc;
  compiler = writeShellScript "firmware-rustc" ''
    exec ${rustc}/bin/rustc --sysroot "$NIX_FIRMWARE_SYSROOT" "$@"
  '';
in
stdenv.mkDerivation {
  pname = "tinted-uefi-firmware";
  version = "0.1.0";
  inherit src;
  nativeBuildInputs = [
    rustc
    cargo
    mold
    lld
    clang
    git
    mkimage
  ];
  dontConfigure = true;
  dontStrip = true;
  postPatch = ''
    git -C third_party/patina apply "$PWD/third_party/patches/dxe-core-loaded-image-system-table.patch"
    git -C third_party/patina-paging apply "$PWD/third_party/patches/paging-protection-only-attributes.patch"
    git -C third_party/patina apply "$PWD/third_party/patches/dxe-core-protocols-next-arg.patch"
  '';
  buildPhase = ''
    export RUSTC_BOOTSTRAP=1
    export PATINA_CONFIG_VERSION=1
    export NIX_FIRMWARE_SYSROOT="$PWD/sysroot"
    mkdir -p sysroot/lib/rustlib/src/rust vendor
    host_sysroot=$(${rustc}/bin/rustc --print sysroot)
    for f in "$host_sysroot"/lib/rustlib/*; do
      ln -s "$f" sysroot/lib/rustlib/
    done
    ln -s ${rust-src} sysroot/lib/rustlib/src/rust/library
    for f in ${deps}/* ${rust-src}/vendor/*; do
      [ -d "$f" ] || continue
      ln -sf "$f" vendor/
    done
    cat >> .cargo/config.toml <<EOF
    [source.crates-io]
    replace-with = "nix-vendor"
    [source.nix-vendor]
    directory = "$PWD/vendor"
    EOF
    export RUSTC=${compiler}
    export CARGO_TARGET_AARCH64_UNKNOWN_UEFI_LINKER=${lld}/bin/lld-link
    cargo build --offline --release -Zbuild-std=core,alloc --target aarch64-unknown-none -p tinted-uefi-firmware
    cargo build --offline --release -Zbuild-std=core,alloc --target aarch64-unknown-uefi -p tinted-boot-platform --features edk2
    CC=${clang.cc}/bin/clang mkimage target/aarch64-unknown-none/release/tinted-boot-aarch64 tinted-boot-aarch64.bin \
      target/aarch64-unknown-uefi/release/tinted-armvirt-dxe-core.efi
  '';
  installPhase = ''
    mkdir -p $out/share/firmware
    cp tinted-boot-aarch64.bin $out/share/firmware/
  '';
  meta = {
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
