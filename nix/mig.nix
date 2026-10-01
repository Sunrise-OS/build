{
  bison,
  clang,
  coreutils,
  flex,
  gnumake,
  gnused,
  lib,
  patch,
  repo,
  src,
  stdenv,
  xnu-src,
}:
stdenv.mkDerivation {
  pname = "xnu-mig";
  version = "138";
  inherit src;
  nativeBuildInputs = [
    bison
    flex
    clang
    gnumake
    coreutils
    gnused
    patch
  ];
  dontConfigure = true;
  buildPhase = ''
    runHook preBuild
    mkdir -p build
    cp -r migcom.tproj build/src
    cd build/src
    patch -p1 < ${repo}/patches/mig-linux-mach-headers.patch
    sed -i 's/y\.tab\.h/parser.tab.h/' lexxer.l
    bison parser.y --header=parser.tab.h --output=parser.tab.c
    flex --header-file=lexxer.yy.h --outfile=lexxer.yy.c lexxer.l
    clang -std=gnu17 -DMIG_VERSION='"migcom-138"' -D_GNU_SOURCE \
      -include ${repo}/nix/mig-include/xnu_mig_compat.h \
      -I. -I${repo}/nix/mig-include -I${xnu-src}/osfmk -I${xnu-src}/libkern \
      error.c global.c header.c mig.c routine.c server.c statement.c \
      string.c type.c user.c utils.c parser.tab.c lexxer.yy.c -o migcom
    ./migcom -version 2>&1 | grep -q migcom
    cd ../..
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p $out/bin $out/libexec
    install -m755 $NIX_BUILD_TOP/source/build/src/migcom $out/libexec/migcom
    install -m755 $NIX_BUILD_TOP/source/build/src/mig.sh $out/bin/mig
    ln -s ${clang}/bin/clang $out/bin/cc
    sed -i \
      -e 's|xcrunPath="/usr/bin/xcrun"|xcrunPath="/nonexistent/xcrun"|' \
      -e 's|^arch=`/usr/bin/arch`$|arch=`uname -m`|' \
      -e 's|`/usr/bin/mktemp|`mktemp|' \
      -e 's|^/bin/rmdir |rmdir |' \
      -e 's| -arch ''${arch}||g' $out/bin/mig
  '';
  meta.platforms = lib.platforms.linux;
}
