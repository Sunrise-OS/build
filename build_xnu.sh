#!/usr/bin/env bash
#
# build_xnu.sh - build the local XNU ARM64/RELEASE/QEMU kernel on Linux.
#
# The kernel is compiled with the system clang/clang++ and the LLVM
# binutils, and linked with mold-macho through clang's --ld-path=ld64.mold
# (set in makedefs/MakeInc.def).  cctools is not used.
#
# The host tools XNU needs - mig + migcom, iig, plutil and availability.pl -
# are built from source into ./tools and reused on later runs, so a plain
# ./build_xnu.sh rebuilds the kernel incrementally.  The object directory is
# left alone unless --clean is given.
#
# Usage: build_xnu.sh [options]
#   -j, --jobs N        parallel make jobs (default: nproc)
#       --clean         remove the ARM64/RELEASE/QEMU objects first
#       --rebuild-tools rebuild the host tools even if already present
#   -t, --tools-only    build the host tools and stop
#       --no-log        do not write build.log
#   -h, --help
#
# Environment overrides:
#   XNU_DIR              XNU source tree        (default: ../xnu)
#   TOOLS_DIR            host tool prefix      (default: ./tools)
#   SRC_DIR              tool checkouts        (default: ./tools-src)
#   BUILD_DIR            host tool build dir   (default: ./tools-build)
#   Q1N1_DIR             q1n1 UEFI source tree  (default: ~/src/q1n1)
#   XNU_ESP_DIR          directory for boot files (default: /tmp/xnu-esp)
#   COMPILER_RT_SRC      compiler-rt source tree (for libclang_rt.profile-xnu.a)
#   LOG                  build log path        (default: ./build.log)
#   BOOTSTRAP_CMDS_DIR, IIG_DIR, XCBUILD_DIR, AVAILABILITY_DIR
#                        pre-existing checkouts, otherwise cloned
#   AVAILABILITY_VERSION version stamped into availability.pl (default 12377.121.6)

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

XNU_DIR=${XNU_DIR:-$SCRIPT_DIR/../xnu}
TOOLS_DIR=${TOOLS_DIR:-$SCRIPT_DIR/tools}
SRC_DIR=${SRC_DIR:-$SCRIPT_DIR/tools-src}
BUILD_DIR=${BUILD_DIR:-$SCRIPT_DIR/tools-build}
LOG=${LOG:-$SCRIPT_DIR/build.log}
COMPILER_RT_SRC=${COMPILER_RT_SRC:-$HOME/src/llvm-project/compiler-rt}
Q1N1_DIR=${Q1N1_DIR:-$HOME/src/q1n1}
XNU_ESP_DIR=${XNU_ESP_DIR:-/tmp/xnu-esp}
AVAILABILITY_VERSION=${AVAILABILITY_VERSION:-12377.121.6}

BOOTSTRAP_CMDS_URL=${BOOTSTRAP_CMDS_URL:-https://github.com/apple-oss-distributions/bootstrap_cmds}
BOOTSTRAP_CMDS_REF=${BOOTSTRAP_CMDS_REF:-bootstrap_cmds-138}
IIG_URL=${IIG_URL:-https://github.com/Sunrise-OS/iig-tools.git}
IIG_REF=${IIG_REF:-96c1ece}
XCBUILD_URL=${XCBUILD_URL:-https://github.com/Sunrise-OS/xcbuild.git}
XCBUILD_REF=${XCBUILD_REF:-9fd9549}
AVAILABILITY_URL=${AVAILABILITY_URL:-https://github.com/apple-oss-distributions/AvailabilityVersions.git}
AVAILABILITY_REF=${AVAILABILITY_REF:-AvailabilityVersions-157.2}

JOBS=$(nproc 2>/dev/null || echo 4)
CLEAN=0
REBUILD_TOOLS=0
TOOLS_ONLY=0
USE_LOG=1

log()  { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        -j|--jobs)        JOBS=$2; shift 2 ;;
        -j*)              JOBS=${1#-j}; shift ;;
        --clean)          CLEAN=1; shift ;;
        --rebuild-tools)  REBUILD_TOOLS=1; shift ;;
        -t|--tools-only)  TOOLS_ONLY=1; shift ;;
        --no-log)         USE_LOG=0; shift ;;
        -h|--help)        usage ;;
        *)                die "unknown option: $1 (try --help)" ;;
    esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# ---- source checkouts -------------------------------------------------------

# pick_dir <env-value> <default-under-SRC_DIR> [legacy-dir ...]
# $1 empty means "not overridden"; returns the first legacy dir that exists,
# else the default under SRC_DIR.
pick_dir() {
    local override=$1 default=$2 d
    shift 2
    if [ -n "$override" ]; then printf '%s\n' "$override"; return; fi
    for d in "$@"; do
        if [ -e "$d" ]; then printf '%s\n' "$d"; return; fi
    done
    printf '%s\n' "$default"
}

fetch_git() { # <dir> <url> <ref>
    local dir=$1 url=$2 ref=$3
    if [ ! -d "$dir/.git" ]; then
        log "cloning $url -> $dir"
        mkdir -p "$(dirname -- "$dir")"
        git clone "$url" "$dir"
    fi
    if [ -n "$ref" ]; then
        log "checking out $ref in $dir"
        git -C "$dir" fetch -q --depth 1 origin "$ref" 2>/dev/null || true
        git -C "$dir" checkout -q "$ref" 2>/dev/null \
            || git -C "$dir" reset -q --hard "$ref" \
            || die "cannot check out $ref in $dir"
    fi
}

bootstrap_cmds_dir() {
    local d
    d=$(pick_dir "${BOOTSTRAP_CMDS_DIR:-}" "$SRC_DIR/bootstrap_cmds" \
                 "$HOME/src/bootstrap_cmds")
    [ -n "${BOOTSTRAP_CMDS_DIR:-}" ] || fetch_git "$d" "$BOOTSTRAP_CMDS_URL" "$BOOTSTRAP_CMDS_REF"
    printf '%s\n' "$d"
}
iig_dir() {
    local d
    d=$(pick_dir "${IIG_DIR:-}" "$SRC_DIR/iig-tools" /tmp/q1n1-iig-tools)
    [ -n "${IIG_DIR:-}" ] || fetch_git "$d" "$IIG_URL" "$IIG_REF"
    printf '%s\n' "$d"
}
xcbuild_dir() {
    local d
    d=$(pick_dir "${XCBUILD_DIR:-}" "$SRC_DIR/xcbuild" /tmp/q1n1-xcbuild)
    [ -n "${XCBUILD_DIR:-}" ] || fetch_git "$d" "$XCBUILD_URL" "$XCBUILD_REF"
    printf '%s\n' "$d"
}
availability_dir() {
    local d
    d=$(pick_dir "${AVAILABILITY_DIR:-}" "$SRC_DIR/AvailabilityVersions" \
                 /tmp/q1n1-AvailabilityVersions)
    [ -n "${AVAILABILITY_DIR:-}" ] || fetch_git "$d" "$AVAILABILITY_URL" "$AVAILABILITY_REF"
    printf '%s\n' "$d"
}

# ---- host tools -------------------------------------------------------------

# The Darwin SDK headers migcom compiles against are not installed on Linux,
# so a handful of thin shims stand in for them.  Only migcom uses these.
emit_mig_headers() {
    local hdr=$TOOLS_DIR/include/mig
    log "writing mig compatibility headers to $hdr"
    mkdir -p "$hdr"/{arm,i386,machine,sys/_types}

    cat > "$hdr/xnu_mig_compat.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_H
#define XNU_MIG_COMPAT_H

#if defined(__aarch64__) && !defined(__arm64__)
#define __arm64__ 1
#endif

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ && !defined(__LITTLE_ENDIAN__)
#define __LITTLE_ENDIAN__ 1
#elif __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__ && !defined(__BIG_ENDIAN__)
#define __BIG_ENDIAN__ 1
#endif

typedef unsigned int u_int;

#define __private_extern__ extern
#define __kernel_ptr_semantics
#define __kernel_data_semantics
#define __kernel_dual_semantics
#define __enum_open
#define __enum_closed
#define __enum_options
#define __enum_decl(name, type, ...)                                           \
  typedef type name;                                                           \
  enum __VA_ARGS__
#define __enum_closed_decl(name, type, ...)                                    \
  typedef type name;                                                           \
  enum __VA_ARGS__
#define __options_decl(name, type, ...)                                        \
  typedef type name;                                                           \
  enum __VA_ARGS__
#define __options_closed_decl(name, type, ...)                                 \
  typedef type name;                                                           \
  enum __VA_ARGS__
#define __WATCHOS_PROHIBITED
#define __TVOS_PROHIBITED

#endif
EOF

    cat > "$hdr/arm/arch.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_ARM_ARCH_H
#define XNU_MIG_COMPAT_ARM_ARCH_H
#define _ARM_ARCH_6 1
#endif
EOF

    cat > "$hdr/arm/_types.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_ARM_TYPES_H
#define XNU_MIG_COMPAT_ARM_TYPES_H
typedef unsigned int __darwin_natural_t;
#endif
EOF

    cat > "$hdr/i386/_types.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_I386_TYPES_H
#define XNU_MIG_COMPAT_I386_TYPES_H
typedef unsigned int __darwin_natural_t;
#endif
EOF

    cat > "$hdr/Availability.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_AVAILABILITY_H
#define XNU_MIG_COMPAT_AVAILABILITY_H
#define __API_AVAILABLE(...)
#define __API_UNAVAILABLE(...)
#endif
EOF

    cat > "$hdr/machine/limits.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_MACHINE_LIMITS_H
#define XNU_MIG_COMPAT_MACHINE_LIMITS_H
#include <limits.h>
#endif
EOF

    cat > "$hdr/machine/types.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_MACHINE_TYPES_H
#define XNU_MIG_COMPAT_MACHINE_TYPES_H
#include <stdint.h>
typedef uintptr_t user_addr_t;
#endif
EOF

    cat > "$hdr/sys/appleapiopts.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_APPLEAPIOPTS_H
#define XNU_MIG_COMPAT_APPLEAPIOPTS_H
#endif
EOF

    cat > "$hdr/sys/_posix_availability.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_POSIX_AVAILABILITY_H
#define XNU_MIG_COMPAT_POSIX_AVAILABILITY_H
#endif
EOF

    cat > "$hdr/sys/_symbol_aliasing.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_SYMBOL_ALIASING_H
#define XNU_MIG_COMPAT_SYMBOL_ALIASING_H
#endif
EOF

    cat > "$hdr/sys/_types.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_SYS_TYPES_H
#define XNU_MIG_COMPAT_SYS_TYPES_H
#include <stdint.h>
typedef uint32_t __darwin_mach_port_t;
typedef unsigned char __darwin_uuid_t[16];
#endif
EOF

    cat > "$hdr/sys/_types/_mach_port_t.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_MACH_PORT_T_H
#define XNU_MIG_COMPAT_MACH_PORT_T_H
#include <sys/_types.h>
typedef __darwin_mach_port_t mach_port_t;
#endif
EOF

    cat > "$hdr/sys/_types/_os_inline.h" <<'EOF'
#ifndef OS_INLINE
#define OS_INLINE static inline
#endif
EOF

    cat > "$hdr/sys/_types/_uuid_t.h" <<'EOF'
#ifndef XNU_MIG_COMPAT_UUID_T_H
#define XNU_MIG_COMPAT_UUID_T_H
#include <sys/_types.h>
typedef __darwin_uuid_t uuid_t;
#endif
EOF
}

build_ar_darwin() {
    cat > "$TOOLS_DIR/bin/ar-darwin" <<'EOF'
#!/bin/sh
exec llvm-ar --format=darwin "$@"
EOF
    chmod +x "$TOOLS_DIR/bin/ar-darwin"
}

# migcom is the C backend behind mig; the mig shell wrapper drives it.
build_mig() {
    local src b inc xnu
    src=$(bootstrap_cmds_dir)
    inc=$TOOLS_DIR/include/mig
    xnu=$XNU_DIR
    b=$BUILD_DIR/mig
    log "building mig/migcom from $src"
    rm -rf "$b"; mkdir -p "$b"
    cp -r "$src/migcom.tproj" "$b/src"

    # migcom's source includes Darwin Mach headers directly. The patch adds
    # minimal Linux-host stubs without modifying the upstream checkout.
    patch -d "$b/src" -p1 < "$SCRIPT_DIR/patches/mig-linux-mach-headers.patch"

    # lexxer.l includes the bison-generated header under its old name.
    sed -i 's/y\.tab\.h/parser.tab.h/' "$b/src/lexxer.l"

    ( cd "$b/src"
      bison parser.y --header=parser.tab.h --output=parser.tab.c
      flex --header-file=lexxer.yy.h --outfile=lexxer.yy.c lexxer.l
      clang -std=gnu17 -DMIG_VERSION='"migcom-138"' -D_GNU_SOURCE \
          -include "$inc/xnu_mig_compat.h" \
          -I. -I"$inc" -I"$xnu/osfmk" -I"$xnu/libkern" \
          error.c global.c header.c mig.c routine.c server.c statement.c \
          string.c type.c user.c utils.c parser.tab.c lexxer.yy.c \
          -o migcom )

    "$b/src/migcom" -version 2>&1 | grep -q 'migcom' \
        || die "built migcom did not report a version"

    install -m 0755 "$b/src/migcom" "$TOOLS_DIR/libexec/migcom"

    # The wrapper is portable except for a few absolute paths and the
    # -arch flag, which Linux clang rejects.
    install -m 0755 "$b/src/mig.sh" "$TOOLS_DIR/bin/mig"
    sed -i \
        -e 's|xcrunPath="/usr/bin/xcrun"|xcrunPath="/nonexistent/xcrun"|' \
        -e 's|^arch=`/usr/bin/arch`$|arch=`uname -m`|' \
        -e 's|`/usr/bin/mktemp|`mktemp|' \
        -e 's|^/bin/rmdir |rmdir |' \
        -e 's| -arch \${arch}||g' \
        "$TOOLS_DIR/bin/mig"
}

build_iig() {
    local src b
    src=$(iig_dir)
    b=$BUILD_DIR/iig
    log "building iig from $src"
    rm -rf "$b"
    cmake -S "$src" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$b" --target iig -j"$JOBS" >/dev/null
    find "$b" -maxdepth 1 -type f -name iig -perm -u+x -exec install -m0755 {} "$TOOLS_DIR/bin/iig" \;
    [ -x "$TOOLS_DIR/bin/iig" ] || die "iig was not produced"
}

build_plutil() {
    local src b
    src=$(xcbuild_dir)
    b=$BUILD_DIR/xcbuild
    log "building plutil from $src"
    cmake -S "$src" -B "$b" -G Ninja -DBUILD_TESTING=OFF \
          -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$b" --target plutil -j"$JOBS" >/dev/null
    install -m 0755 "$b/plutil" "$TOOLS_DIR/bin/plutil"
}

build_availability() {
    local src out=$TOOLS_DIR/devroot/usr/local/libexec
    src=$(availability_dir)
    log "building availability.pl from $src"
    ( cd "$src"
      mkdir -p obj
      python3 ./availability --av_version "$AVAILABILITY_VERSION" \
              --preprocess ./availability obj/availability >/dev/null )
    mkdir -p "$out"
    install -m 0755 "$src/obj/availability" "$out/availability.pl"
}

ensure_tools() {
    need_cmd clang
    need_cmd clang++
    need_cmd git
    need_cmd clang
    need_cmd flex
    need_cmd bison
    need_cmd cmake
    need_cmd ninja
    need_cmd llvm-ar
    need_cmd llvm-config
    need_cmd python3
    need_cmd patch
    need_cmd unifdef
    need_cmd tcsh

    mkdir -p "$TOOLS_DIR/bin" "$TOOLS_DIR/libexec" \
             "$TOOLS_DIR/devroot/usr/local/libexec" "$BUILD_DIR" "$SRC_DIR"

    # The mig wrapper looks for the C compiler as $MIGCC and falls back to
    # a bare `cc` next to itself when MIGCC is unset.
    [ -e "$TOOLS_DIR/bin/cc" ] || ln -sf "$(command -v clang)" "$TOOLS_DIR/bin/cc"

    build_ar_darwin
    emit_mig_headers

    local stamp=$TOOLS_DIR/.stamp
    if [ "$REBUILD_TOOLS" = 0 ] && [ -f "$stamp" ] \
       && [ -x "$TOOLS_DIR/bin/mig" ] && [ -x "$TOOLS_DIR/libexec/migcom" ] \
       && [ -x "$TOOLS_DIR/bin/iig" ] && [ -x "$TOOLS_DIR/bin/plutil" ] \
       && [ -x "$TOOLS_DIR/devroot/usr/local/libexec/availability.pl" ]; then
        log "host tools already built (use --rebuild-tools to refresh)"
    else
        build_mig
        build_iig
        build_plutil
        build_availability
        date > "$stamp"
    fi

    "$TOOLS_DIR/bin/mig" -version >/dev/null 2>&1 \
        || warn "mig -version failed; mig may not work"
}

# ---- kernel -----------------------------------------------------------------

build_kernel() {
    need_cmd make

    # mold-macho is invoked as `clang --ld-path=ld64.mold`, so the binary
    # has to be reachable as ld64.mold on PATH.
    local mold
    mold=$(command -v ld64.mold 2>/dev/null || true)
    [ -n "$mold" ] || die "ld64.mold (mold-macho) not found on PATH; install mold-macho first"
    log "kernel linker: $mold"

    [ -d "$XNU_DIR" ] || die "XNU tree not found: $XNU_DIR"

    if [ "$CLEAN" = 1 ]; then
        log "removing stale XNU build and exported-header outputs"
        rm -rf "$XNU_DIR/BUILD/obj/RELEASE_ARM64_QEMU" \
               "$XNU_DIR/BUILD/obj/EXPORT_HDRS"
    fi

    [ -n "$COMPILER_RT_SRC" ] || die "COMPILER_RT_SRC is empty"
    if [ ! -d "$COMPILER_RT_SRC" ]; then
        warn "COMPILER_RT_SRC ($COMPILER_RT_SRC) does not exist;"
        warn "libclang_rt.profile-xnu.a will fail to build (fetch compiler-rt sources)"
    fi

    log "building kernel: ARCH_CONFIGS=ARM64 KERNEL_CONFIGS=RELEASE MACHINE_CONFIGS=QEMU PRE_LTO=0 -j$JOBS"

    export PATH="$TOOLS_DIR/bin:$(dirname -- "$mold"):$PATH"
    local rc=0
    make -C "$XNU_DIR" \
        CC=clang CXX=clang++ HOST_CC=clang HOST_CXX=clang++ \
        DO_CTFMERGE=0 \
        FAKEROOT_DIR="$TOOLS_DIR/devroot" \
        MIGCC=clang \
        COMPILER_RT_PROFILE_SOURCE="$COMPILER_RT_SRC" \
        AR=ar-darwin \
        ARCH_CONFIGS=ARM64 KERNEL_CONFIGS=RELEASE MACHINE_CONFIGS=QEMU \
        BUILD_LTO=0 \
        USE_LTO=0 \
        PRE_LTO=0 \
        BUILD_WERROR=0 \
        -j"$JOBS" || rc=$?

    local kernel=$XNU_DIR/BUILD/obj/RELEASE_ARM64_QEMU/kernel.release.qemu
    if [ "$rc" != 0 ]; then
        die "make failed (rc=$rc); see ${USE_LOG:+$LOG}"
    fi
    [ -f "$kernel" ] || die "make succeeded but $kernel is missing"

    log "built $kernel ($(stat -c %s "$kernel" 2>/dev/null || echo '?') bytes)"
    llvm-nm "$kernel" 2>/dev/null | awk '$3=="__mh_execute_header"{printf "    __mh_execute_header = %s\n",$1}'
    llvm-objdump --macho --private-headers "$kernel" 2>/dev/null \
        | awk '/segname __TEXT/{s=1} s&&/vmaddr/&&!p{printf "    __TEXT vmaddr = %s\n",$2; p=1}'

    [ -d "$Q1N1_DIR" ] || die "q1n1 tree not found: $Q1N1_DIR"
    log "building q1n1 UEFI loader"
    make -C "$Q1N1_DIR" uefi

    mkdir -p "$XNU_ESP_DIR"
    log "building AFDT at $XNU_ESP_DIR/AFDT"
    python3 "$SCRIPT_DIR/qemu/mkafdt.py" \
        --output "$XNU_ESP_DIR/AFDT" --ramdisk-size 4096
    [ -s "$XNU_ESP_DIR/AFDT" ] || die "AFDT was not produced"
}

# ---- main -------------------------------------------------------------------

main() {
    ensure_tools
    [ "$TOOLS_ONLY" = 1 ] && { log "tools only; done"; exit 0; }

    if [ "$USE_LOG" = 1 ]; then
        log "logging to $LOG"
        build_kernel 2>&1 | tee "$LOG"
        exit "${PIPESTATUS[0]}"
    fi
    build_kernel
}

main
