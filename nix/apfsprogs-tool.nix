{ lib, stdenv, src, tool, patches ? [] }:
stdenv.mkDerivation {
  pname = "apfsprogs-${tool}";
  version = "0.2.1";
  inherit src patches;
  enableParallelBuilding = true;
  buildPhase = ''
    runHook preBuild
    make -C ${tool} GIT_COMMIT=3721463 CC="$CC" -j"$NIX_BUILD_CORES"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    make -C ${tool} install DESTDIR="$out"
    runHook postInstall
  '';
  meta = {
    description = "Experimental APFS ${tool} tool for Linux";
    homepage = "https://github.com/linux-apfs/apfsprogs";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
    mainProgram = tool;
  };
}
