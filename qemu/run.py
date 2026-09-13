#!/usr/bin/env python3
"""Boot U-Boot + bootxnu on qemu-system-aarch64 -M virt.

Loads:
  kernel Mach-O  @ 0x44000000
  Apple FDT      @ 0x46000000
  PID1 RAMDisk   @ 0x48000000

Then waits for the U-Boot prompt and issues bootxnu.
"""
from __future__ import annotations

import argparse
import os
import pty
import select
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_UBOOT = Path.home() / "src" / "u-boot" / "u-boot.bin"
KERNEL_ADDR = "0x44000000"
FDT_ADDR = "0x46000000"
RAMDISK_ADDR = "0x48000000"


def qemu_cmd(uboot: Path, kernel: Path, afdt: Path, init: Path, extra: list[str], cpu: str, gic: str) -> list[str]:
    gic_opt = f"virt,gic-version={gic}"
    return [
        "qemu-system-aarch64",
        "-M",
        gic_opt,
        "-cpu",
        cpu,
        "-m",
        "1G",
        "-nographic",
        "-bios",
        str(uboot),
        "-device",
        f"loader,file={kernel},addr={KERNEL_ADDR},force-raw=on",
        "-device",
        f"loader,file={afdt},addr={FDT_ADDR},force-raw=on",
        "-device",
        f"loader,file={init},addr={RAMDISK_ADDR},force-raw=on",
        *extra,
    ]


def run(cmd: list[str], timeout: float, expect: str) -> int:
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
    buf = b""
    sent_boot = False
    interrupted = False
    deadline = time.time() + timeout
    saw_pid1 = False
    try:
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.2)
            if fd in r:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                buf += chunk
                text = buf.decode("utf-8", "replace")
                if (not interrupted) and ("Hit any key" in text or "U-Boot" in text):
                    os.write(fd, b"\r")
                    interrupted = True
                if (not sent_boot) and "=> " in text:
                    boot = (
                        f"setenv bootargs 'rd=md0 -v serial=3 debug=0x14e keepsyms=1 cs_enforcement_disable=1 amfi_allow_any_signature=1'\r"
                        f"bootxnu {KERNEL_ADDR} {FDT_ADDR}\r"
                    )
                    os.write(fd, boot.encode())
                    sent_boot = True
                if expect.encode() in buf:
                    saw_pid1 = True
                    # give a moment for the rest of the banner
                    time.sleep(0.4)
                    break
        if not saw_pid1:
            return 1
        return 0
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--uboot", default=str(DEFAULT_UBOOT))
    p.add_argument("--kernel", default=str(HERE / "out" / "mock_kernel.macho"))
    p.add_argument("--afdt", default=str(HERE / "out" / "afdt.bin"))
    p.add_argument("--init", default=str(HERE / "out" / "od_init.macho"))
    p.add_argument("--timeout", type=float, default=30)
    p.add_argument("--expect", default="Hello from OpenDarwin PID 1")
    p.add_argument("--cpu", default="cortex-a53", help="qemu -cpu (fork QEMU.h board is cortex-a53)")
    p.add_argument("--gic", default="2", help="qemu virt gic-version (fork QEMU.h board is GICv2)")
    p.add_argument("--interactive", action="store_true")
    args, extra = p.parse_known_args()
    for path in (args.uboot, args.kernel, args.afdt, args.init):
        if not Path(path).is_file():
            raise SystemExit(f"missing {path} (run make in {HERE})")
    cmd = qemu_cmd(Path(args.uboot), Path(args.kernel), Path(args.afdt), Path(args.init), extra, args.cpu, args.gic)
    print("+", " ".join(cmd), flush=True)
    if args.interactive:
        os.execvp(cmd[0], cmd)
    rc = run(cmd, args.timeout, args.expect)
    if rc != 0:
        print(f"\n[run.py] did not see {args.expect!r} within {args.timeout}s", file=sys.stderr)
    sys.exit(rc)


if __name__ == "__main__":
    main()
