#!/usr/bin/env python3
"""Validate a disposable APFS image. Never opens block devices or writes input."""
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


def run(*args, ok=True):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if (result.returncode == 0) != ok:
        raise RuntimeError(f"Unexpected exit {result.returncode}: {args!r}\n{result.stdout}")
    return result.stdout


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def main():
    path = Path(sys.argv[1]).resolve()
    if not stat.S_ISREG(path.stat().st_mode):
        raise ValueError("Only regular image files are accepted; block devices are forbidden")
    original = digest(path)
    run("apfsck", str(path))
    info = run("hadris-apfs", "info", str(path))
    for expected in ("block size: 4096", "block count: 65536", "'XNU'", "files 0"):
        if expected not in info:
            raise RuntimeError(f"Missing expected metadata {expected!r}\n{info}")
    listing = run("hadris-apfs", "ls", str(path))
    if listing.strip() != "XNU:":
        raise RuntimeError(f"Expected empty root directory, got {listing!r}")
    run("hadris-apfs", "cat", str(path), "/missing", ok=False)
    if digest(path) != original:
        raise RuntimeError("Read-only validators modified the image")
    print("PASS: independent apfsck validation, Hadris volume discovery and empty-directory listing")
    print("PASS: missing file rejected; validators leave input unchanged")

    with tempfile.TemporaryDirectory(prefix="apfs-validation-") as tmp:
        second = Path(tmp) / "second.img"
        with second.open("xb") as file:
            file.truncate(256 * 1024 * 1024)
        os.environ["SOURCE_DATE_EPOCH"] = "1"
        run("mkapfs", "-s", "-z", "-L", "XNU",
            "-U", "6bf57e62-d9bd-4fba-9189-cf1b9d613f19",
            "-u", "f3eb5f9b-9b58-44e6-8bf5-ff831ba8be0d", str(second))
        if digest(second) != original:
            raise RuntimeError("Repeated formatting is not byte-identical")
        print("PASS: repeated formatting produces byte-identical images")
        with second.open("r+b") as file:
            file.seek(8)
            value = file.read(1)
            file.seek(8)
            file.write(bytes([value[0] ^ 1]))
        run("hadris-apfs", "info", str(second), ok=False)
        run("apfsck", str(second), ok=False)
        print("PASS: corrupt container checksum rejected by both readers")
    print(f"SHA256: {original}")


if __name__ == "__main__":
    main()
