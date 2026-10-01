{
  lib,
  stdenv,
  kext-compiler,
  name,
  src,
  sourceFile,
  plistFile,
  extraFlags ? [ ],
}:
stdenv.mkDerivation {
  pname = name;
  version = "1.0.0";
  inherit src;
  nativeBuildInputs = [ kext-compiler ];
  dontConfigure = true;
  dontStrip = true;
  buildPhase = ''
    runHook preBuild
    compile-kext ${sourceFile} kext.o ${lib.escapeShellArgs extraFlags}
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p $out
    cp kext.o $out/kext.o
    cp ${plistFile} $out/Info.plist
  '';
  meta.platforms = lib.platforms.linux;
}
