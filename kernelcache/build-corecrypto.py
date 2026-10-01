#!/usr/bin/env python3
"""Cross-compile Apple's corecrypto kext sources and link an MH_KEXT_BUNDLE.

This is NOT yet a kernelcache builder; the kext is unprelinked.
Apple sources remain in a separate, user-provided checkout (see its License.txt).
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REVISION = "9612a959abb6eac0aac3ee6a7245c46365c9d81b"
ROOT = Path(__file__).resolve().parent.parent


def run(argv, **kwargs):
    return subprocess.check_output(argv, text=True, **kwargs).strip()


def kext_sources(source):
    """Use Apple's target manifest rather than a glob of unrelated/test sources."""
    project = (source / "corecrypto.xcodeproj/project.pbxproj").read_text()
    target = re.search(
        r'/\* corecrypto_kext \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};',
        project, re.S)
    if not target:
        raise ValueError("cannot locate corecrypto_kext target")
    phase_id = re.search(r'([A-F0-9]{24}) /\* Sources \*/', target[1])[1]
    phase = re.search(r'\n\t\t' + phase_id + r' /\* Sources \*/ = \{(.*?)\n\t\t\};', project, re.S)
    names = re.findall(r'/\* (.*?) in Sources \*/', phase[1])
    # CC_USE_ASM=0 selects Apple's portable implementation. Assembly sources
    # and their architecture-specific implementations are not needed.
    index = {}
    for path in source.rglob("*.c"):
        index.setdefault(path.name, []).append(path)
    result = []
    for name in names:
        if not name.endswith(".c"):
            continue
        matches = index.get(name, [])
        if len(matches) != 1:
            raise ValueError(f"ambiguous or missing source {name}: {matches}")
        result.append(matches[0])
    if not result or len(result) != len(set(result)):
        raise ValueError("empty or duplicate source manifest")
    return result


def undefined_symbols(nm, image):
    return {line.split()[-1] for line in run([nm, "--undefined-only", str(image)]).splitlines() if line.split()}


def verify_source(source, required_revision, source_revision=None):
    """Accept a fetcher's revision attestation, or verify a clean Git checkout."""
    revision = source_revision or run(["git", "-C", str(source), "rev-parse", "HEAD"])
    if revision != required_revision:
        raise ValueError(f"source commit {revision} does not match {required_revision}")
    if source_revision is None and run(["git", "-C", str(source), "status", "--porcelain"]):
        raise ValueError("corecrypto checkout must be clean")
    return revision


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path.home() / "src/corecrypto")
    parser.add_argument("--xnu", type=Path, default=ROOT.parent / "xnu")
    parser.add_argument("--output", type=Path, default=ROOT / "corecrypto-build")
    parser.add_argument("--revision", default=REVISION, help="required source commit")
    parser.add_argument("--kernel", type=Path, help="kernel whose defined symbols satisfy the imports")
    parser.add_argument("--source-revision", help="revision attested by a fixed source fetcher (e.g. Nix); no .git required")
    parser.add_argument("--clang", default="clang")
    parser.add_argument("--ld", default="ld64.mold")
    parser.add_argument("--nm", default="llvm-nm")
    parser.add_argument("--mcpu", default="cortex-a53", help="lowest CPU to support (QEMU cortex-a76 has no SHA3)")
    parser.add_argument("--otool", default="llvm-otool")
    parser.add_argument("-j", "--jobs", type=int, default=min(os.cpu_count() or 1, 8))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("jobs must be positive")
    source, xnu, output = (p.resolve() for p in (args.source, args.xnu, args.output))
    revision = verify_source(source, args.revision, args.source_revision)
    exports = xnu / "BUILD/obj/EXPORT_HDRS"
    config = xnu / "BUILD/obj/DEVELOPMENT_ARM64_QEMU/libkern/DEVELOPMENT"
    if not config.is_dir():
        config = xnu / "BUILD/obj/RELEASE_ARM64_QEMU/libkern/RELEASE"
    if not (exports / "libkern/libkern/crypto/register_crypto.h").exists() or not config.is_dir():
        raise ValueError("build XNU first: exported headers and QEMU configuration are required")
    sources = kext_sources(source)
    output.mkdir(parents=True, exist_ok=True)
    include = output / "include/corecrypto"
    include.mkdir(parents=True, exist_ok=True)
    for old in include.iterdir():
        if not old.is_symlink():
            raise ValueError(f"refusing to remove non-symlink {old}")
        old.unlink()
    for header in sorted(source.glob("*/corecrypto/*.h")):
        dest = include / header.name
        if dest.is_symlink():
            raise ValueError(f"duplicate public header {header.name}")
        dest.symlink_to(header)
    flags = [args.clang, "-target", "arm64-apple-macos15", "-mkernel",
             "-ffreestanding", "-nostdlibinc", "-fno-builtin", "-O2", "-g",
             "-DBUILDKERNEL", "-DKERNEL", "-DKERNEL_PRIVATE", "-DPRIVATE",
             "-DCC_USE_ASM=0", "-DCC_DISABLE_RSAKEYGEN=1", "-mbranch-protection=bti", "-mcpu=" + args.mcpu,
             "-DARM64_BOARD_CONFIG_QEMU", "-DXNU_TARGET_OS_OSX",
             "-DARM64", "-D__ARM64__", "-DLP64", "-I" + str(output / "include")]
    for component in sorted(source.iterdir()):
        if component.is_dir() and component.name != ".git":
            for directory in (component, component / "corecrypto", component / "src"):
                if directory.is_dir():
                    flags.append("-I" + str(directory))
    flags.append("-I" + str(source / "acceleratecrypto/Header"))
    for directory in sorted(exports.iterdir()):
        if directory.is_dir():
            flags.append("-I" + str(directory))
    flags.extend(["-I" + str(config), "-I" + str(xnu / "EXTERNAL_HEADERS")])
    objects = output / "obj"
    objects.mkdir(exist_ok=True)
    module = output / "module.c"
    module.write_text('''#include <mach/mach_types.h>
#include <mach/kmod.h>
extern kern_return_t corecrypto_kext_start(kmod_info_t *, void *);
extern kern_return_t corecrypto_kext_stop(kmod_info_t *, void *);
KMOD_EXPLICIT_DECL(com.apple.kec.corecrypto, "26.0",
                   corecrypto_kext_start, corecrypto_kext_stop)
''')

    def compile_one(path):
        obj = objects / (path.name + ".o")
        proc = subprocess.run(flags + ["-c", str(path), "-o", str(obj)], capture_output=True, text=True)
        if proc.returncode:
            raise RuntimeError(f"{path}:\n{proc.stderr}")
        if proc.stderr:
            print(proc.stderr, file=sys.stderr, end="")
        return obj

    print(f"Compiling {len(sources)} Apple sources and module declaration ({revision})", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        built = list(pool.map(compile_one, sources + [module]))
    # Explicit list prevents stale objects from earlier builds being linked.
    image = output / "corecrypto.o"
    subprocess.run([args.ld, "-arch", "arm64", "-r", *map(str, built), "-o", str(image)], check=True)
    # mold-macho's -kext: MH_KEXT_BUNDLE, no libSystem/dyld, kernel imports left undefined.
    kext = output / "corecrypto.kext"
    link = subprocess.run([args.ld, "-arch", "arm64", "-kext", str(image), "-o", str(kext)],
                          capture_output=True, text=True)
    if link.returncode:
        raise RuntimeError(f"{args.ld} cannot link with -kext (install a mold-macho with -kext support):\n{link.stderr}")
    header = run([args.otool, "-hv", str(kext)])
    if not re.search(r"KEXT_?BUNDLE", header):
        raise ValueError("linked image is not MH_KEXT_BUNDLE:\n" + header)
    imports = undefined_symbols(args.nm, kext)
    kernel = args.kernel or xnu / "BUILD/obj/DEVELOPMENT_ARM64_QEMU/kernel.development.qemu"
    if args.kernel is None and not kernel.exists():
        kernel = xnu / "BUILD/obj/RELEASE_ARM64_QEMU/kernel.release.qemu"
    kernel = kernel.resolve()
    defined = {line.split()[-1] for line in run([args.nm, "--defined-only", str(kernel)]).splitlines() if line.split()}
    missing = sorted(imports - defined)
    if missing:
        raise ValueError("kernel does not supply imports: " + ", ".join(missing))
    (output / "manifest.json").write_text(json.dumps({
        "stage": "linked-kext-not-prelinked", "revision": revision,
        "source": str(source), "kernel": str(kernel), "compile_flags": flags,
        "sources": [str(p.relative_to(source)) for p in sources],
        "imports": sorted(imports), "object": str(image), "kext": str(kext),
    }, indent=2) + "\n")
    print(f"Built {kext}; all {len(imports)} imports exist in {kernel}")
    print("Still requires FIPS HMAC, prelinking and kernelcache packaging.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
