#!/usr/bin/env python3
"""Compile one source with the exact flags XNU used for a kernel component.

Usage: kcc.py [--component bsd] [--xnu DIR] -o OBJECT SOURCE [-- extra clang args...]

The component's .CFLAGS file is a single shell-ish line in which some -D values
contain spaces inside parentheses, so it is re-tokenised by balancing them.
Kexts that use XNU-private interfaces (libpthread) need this exact environment.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path


def kernel_flags(xnu, component, cxx=False):
    path = xnu / "BUILD/obj/RELEASE_ARM64_QEMU" / component / "RELEASE" / (".CXXFLAGS" if cxx else ".CFLAGS")
    text = path.read_text().split("\0")[0]
    tokens, current, depth = [], "", 0
    for word in text.split():
        current = f"{current} {word}" if current else word
        depth += word.count("(") - word.count(")")
        if depth <= 0:
            tokens.append(current)
            current, depth = "", 0
    if tokens and tokens[0] == "clang" or tokens[0] == "clang++":
        tokens = tokens[1:]
    # Drop debug info, dependency output and anything that is not a flag.
    flags, skip = [], False
    for token in tokens:
        if skip:
            skip = False
            flags.append(token)
            continue
        if token in ("-include", "-target", "-isystem", "-arch", "-x"):
            skip = True
            flags.append(token)
            continue
        if token.startswith("-") and token not in ("-g",):
            flags.append(token)
    return flags, path.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xnu", type=Path, default=Path(__file__).resolve().parent.parent.parent / "xnu")
    parser.add_argument("--component", default="bsd")
    parser.add_argument("--clang", default="clang")
    parser.add_argument("-o", "--output", type=Path, required=True)
    parser.add_argument("source", type=Path)
    parser.add_argument("extra", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    extra = args.extra[1:] if args.extra[:1] == ["--"] else args.extra
    cxx = args.source.suffix == ".cpp"
    flags, cwd = kernel_flags(args.xnu.resolve(), args.component, cxx)
    compiler = args.clang + ("++" if cxx else "")
    cmd = [compiler, *flags, *extra, "-c", str(args.source.resolve()), "-o", str(args.output.resolve())]
    sys.exit(subprocess.run(cmd, cwd=cwd).returncode)


if __name__ == "__main__":
    main()
