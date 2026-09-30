#!/usr/bin/env python3
"""Build the Apple Flattened Device Tree (AFDT) for booting the opendarwin
XNU kernel via u-boot's bootxnu on qemu-system-aarch64 -M virt.

Layout matches XNU's DTNode / DTProperty encoding (little-endian):
  u32 nproperties, u32 nchildren
  for each property: char name[32], u32 length, data padded to 4 bytes
  then children recursively.

bootxnu copies this blob into boot_args->afdt. This is a faithful port of
the AFDT builder that used to live in opendarwin-project/xnu
tools/qemu-boot (src/afdt.rs), which the fork's pexpert/arm64/QEMU.h
documents as "the only source of the device tree this board boots with".
A minimal /chosen-only tree is NOT enough for the real kernel:

  * pe_serial.c: get_serial_device_phandle() panics if there is no
    "defaults" node (it reads "serial-device" phandle from it or the
    serial-device-name=uart0 boot arg, then "AAPL,phandle" on uart0);
    serial_init() gives up on a console entirely if there is no "arm-io"
    node (pe_arm_get_soc_base_phys() -> 0).
  * pe_identify_machine.c: pe_arm_get_soc_base_phys() reads arm-io
    "ranges" (second u64 becomes gPESoCBasePhys); the PL011 driver's reg
    block_offset is relative to that SoC base.

Board constants (qemu virt, gic-version=3, a 16K-granule CPU such as
cortex-a76):
  RAM      @ 0x40000000
  GICD     @ 0x08000000   (arm-io ranges value -> SoC base)
  GICR     @ 0x080A0000   (/arm-io/gic reg, 4 x u64, for pe_fiq.c)
  PL011    @ 0x09000000   (uart0 reg = 0x01000000 relative to SoC base)
  PL031    @ 0x09010000   (dummy timer node)
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

GICD_BASE = 0x08000000
GICD_SIZE = 0x10000
GICR_BASE = 0x080A0000
GICR_SIZE = 0xF60000   # virt's redistributor window, 0x20000 per PE
PL011_BASE = 0x09000000
PL031_BASE = 0x09010000
UART_PHANDLE = 0x100

DEFAULT_BOOT_ARGS = "rd=md0 -v serial=3 debug=0x14e keepsyms=1 serial-device-name=uart0"


def _pad4(n: int) -> int:
    return (n + 3) & ~3


def _prop(name: str, data: bytes) -> bytes:
    raw = name.encode("ascii") + b"\x00"
    if len(raw) > 32:
        raise ValueError(f"property name too long: {name}")
    return raw.ljust(32, b"\x00") + struct.pack("<I", len(data)) + data.ljust(_pad4(len(data)), b"\x00")


def _str(data: str) -> bytes:
    return data.encode("ascii") + b"\x00"


def _node(props: list[bytes], children: list[bytes]) -> bytes:
    return struct.pack("<II", len(props), len(children)) + b"".join(props) + b"".join(children)


def build_afdt(
    ram_base: int,
    ram_size: int,
    ramdisk_phys: int,
    ramdisk_size: int,
    boot_args: str,
    panic_log_phys: int = 0,
    panic_log_size: int = 0x80000,
) -> bytes:
    if panic_log_phys == 0:
        panic_log_phys = ram_base + ram_size - panic_log_size
    root = _node(
        [
            _prop("name", _str("device-tree")),
            # matched by kernelcache/drivers/OSSPlatformExpert (IONameMatch)
            _prop("compatible", _str("qemu,virt")),
            _prop("model", _str("QEMU,virt")),
        ],
        [
            _chosen(ram_base, ram_size, ramdisk_phys, ramdisk_size, boot_args, panic_log_size),
            _defaults(),
            _arm_io(),
            _cpus(),
            _pram(panic_log_phys, panic_log_size),
        ],
    )
    return root


def _chosen(
    ram_base: int,
    ram_size: int,
    ramdisk_phys: int,
    ramdisk_size: int,
    boot_args: str,
    panic_log_size: int = 0x80000,
) -> bytes:
    # Layout placeholder only: q1n1 must replace this via EFI RNG each boot.
    # All-zero input also fails XNU's seed sanity check with an older loader.
    random_seed = bytes(256)
    memory_map = _node(
        [
            _prop("name", _str("memory-map")),
            _prop("RAMDisk", struct.pack("<QQ", ramdisk_phys, ramdisk_size)),
        ],
        [],
    )
    return _node(
        [
            _prop("name", _str("chosen")),
            _prop("dram-base", struct.pack("<Q", ram_base)),
            _prop("dram-size", struct.pack("<Q", ram_size)),
            _prop("firmware-version", _str("q1n1-0.1.0")),
            _prop("system-firmware-version", _str("q1n1-0.1.0")),
            _prop("boot-args", _str(boot_args)),
            _prop("unique-chip-id", bytes([1, 2, 3, 4, 5, 6, 7, 8])),
            _prop("embedded-panic-log-size", struct.pack("<I", panic_log_size)),
            _prop("kernel-ctrr-to-be-enabled", struct.pack("<I", 0)),
            _prop("debug-enabled", struct.pack("<I", 1)),
            _prop("random-seed", random_seed),
        ],
        [memory_map],
    )


def _defaults() -> bytes:
    return _node(
        [
            _prop("name", _str("defaults")),
            # phandle of uart0; pe_serial.c get_serial_device_phandle() reads
            # this (or the serial-device-name=uart0 boot arg) to find the
            # console.
            _prop("serial-device", struct.pack("<I", UART_PHANDLE)),
        ],
        [],
    )


def _arm_io() -> bytes:
    uart0 = _node(
        [
            _prop("name", _str("uart0")),
            _prop("compatible", _str("arm,pl011")),
            _prop("reg", struct.pack("<QQ", PL011_BASE - GICD_BASE, 0x1000)),
            _prop("AAPL,phandle", struct.pack("<I", UART_PHANDLE)),
        ],
        [],
    )
    gic = _node(
        [
            _prop("name", _str("gic")),
            _prop("interrupt-controller", _str("master")),
            _prop("compatible", _str("arm,gic-v3")),
            # GICD base/size, GICR base/size, relative to the SoC base
            # (pexpert/arm/pe_fiq.c needs all four).
            _prop("reg", struct.pack("<QQQQ", 0, GICD_SIZE,
                                     GICR_BASE - GICD_BASE, GICR_SIZE)),
        ],
        [],
    )
    timer = _node(
        [
            _prop("name", _str("timer")),
            _prop("device_type", _str("timer")),
            _prop("reg", struct.pack("<QQ", PL031_BASE - GICD_BASE, 0x1000)),
        ],
        [],
    )
    return _node(
        [
            _prop("name", _str("arm-io")),
            _prop("device_type", _str("arm-io")),
            # second u64 becomes gPESoCBasePhys (pe_identify_machine.c)
            _prop("ranges", struct.pack("<QQ", 0, GICD_BASE)),
        ],
        [uart0, gic, timer],
    )


def _cpus() -> bytes:
    cpu0 = _node(
        [
            _prop("name", _str("cpu0")),
            _prop("state", _str("running")),
            _prop("reg", struct.pack("<I", 0)),
            _prop("timebase-frequency", struct.pack("<I", 62_500_000)),
            _prop("clock-frequency", struct.pack("<I", 1_000_000_000)),
        ],
        [],
    )
    return _node([_prop("name", _str("cpus"))], [cpu0])


def _pram(phys: int, size: int) -> bytes:
    return _node(
        [
            _prop("name", _str("pram")),
            _prop("reg", struct.pack("<QQ", phys, size)),
        ],
        [],
    )


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("-o", "--output", required=True)
    p.add_argument("--ram-base", default="0x40000000")
    p.add_argument("--ram-size", default="0x40000000", help="full DRAM bank size (1G for -m 1G)")
    p.add_argument("--ramdisk-phys", default="0x48000000")
    p.add_argument("--ramdisk", help="PID1 Mach-O; size taken from this file")
    p.add_argument("--ramdisk-size", default="0")
    p.add_argument("--boot-args", default=DEFAULT_BOOT_ARGS)
    p.add_argument("--panic-log-phys", default="0")
    p.add_argument("--panic-log-size", default="0x80000")
    args = p.parse_args()

    size = int(args.ramdisk_size, 0)
    if args.ramdisk:
        size = Path(args.ramdisk).stat().st_size
    if size <= 0:
        raise SystemExit("ramdisk size is 0")
    # IOKitBSDInit truncates via >> 12 (4K pages) when calling mdevadd; round up
    # to page boundary so the mockfs memory device covers the entire Mach-O
    size = (size + 4095) & ~4095

    blob = build_afdt(
        int(args.ram_base, 0),
        int(args.ram_size, 0),
        int(args.ramdisk_phys, 0),
        size,
        args.boot_args,
        int(args.panic_log_phys, 0),
        int(args.panic_log_size, 0),
    )
    Path(args.output).write_bytes(blob)
    print(f"wrote {args.output} ({len(blob)} bytes, RAMDisk phys={args.ramdisk_phys} size={size})")


if __name__ == "__main__":
    main()
