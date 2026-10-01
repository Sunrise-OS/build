{
  lib,
  stdenv,
  rustc,
  src,
  name,
}:
stdenv.mkDerivation {
  pname = name;
  version = "0.1.0";
  inherit src;
  nativeBuildInputs = [ rustc ];
  dontConfigure = true;
  buildPhase = ''
    CARGO_MANIFEST_DIR=${src}/tools/${name} rustc --edition=2024 -C opt-level=3 tools/${name}/src/main.rs -o ${name}
  '';
  installPhase = ''
    mkdir -p $out/bin
    install -m755 ${name} $out/bin/
  '';
  meta = {
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
