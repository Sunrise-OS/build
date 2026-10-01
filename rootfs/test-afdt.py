#!/usr/bin/env python3
"""Check disk-root AFDT selection without relying on the guest kernel."""
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "qemu" / "mkafdt.py"
spec = importlib.util.spec_from_file_location("mkafdt", SOURCE)
mkafdt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mkafdt)


def parse_node(blob, offset=0):
    count, children = struct.unpack_from("<II", blob, offset)
    offset += 8
    props = {}
    for _ in range(count):
        name = blob[offset:offset + 32].split(b"\0", 1)[0].decode("ascii")
        length, = struct.unpack_from("<I", blob, offset + 32)
        offset += 36
        props[name] = blob[offset:offset + length]
        offset += (length + 3) & ~3
    nodes = {}
    for _ in range(children):
        child, offset = parse_node(blob, offset)
        nodes[child["props"]["name"].rstrip(b"\0").decode("ascii")] = child
    return {"props": props, "children": nodes}, offset


class AFDTTests(unittest.TestCase):
    def tree(self, size, args):
        blob = mkafdt.build_afdt(0x40000000, 0x40000000, 0x58000000, size, args)
        tree, end = parse_node(blob)
        self.assertEqual(end, len(blob))
        return tree["children"]["chosen"]

    def test_disk_root_omits_ramdisk(self):
        chosen = self.tree(0, "rd=disk0 -v")
        self.assertEqual(chosen["props"]["boot-args"], b"rd=disk0 -v\0")
        self.assertNotIn("RAMDisk", chosen["children"]["memory-map"]["props"])
        self.assertEqual(len(chosen["props"]["random-seed"]), 256)

    def test_existing_ramdisk_layout(self):
        chosen = self.tree(4096, mkafdt.DEFAULT_BOOT_ARGS)
        self.assertEqual(chosen["children"]["memory-map"]["props"]["RAMDisk"],
                         struct.pack("<QQ", 0x58000000, 4096))

    def test_cli_explicit_disk_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "AFDT"
            subprocess.run([sys.executable, str(SOURCE), "--output", str(output),
                            "--no-ramdisk", "--boot-args", "rd=disk0"], check=True,
                           stdout=subprocess.PIPE)
            tree, _ = parse_node(output.read_bytes())
            self.assertNotIn("RAMDisk", tree["children"]["chosen"]["children"]["memory-map"]["props"])
            conflict = subprocess.run([sys.executable, str(SOURCE), "--output", str(output),
                                       "--no-ramdisk", "--ramdisk-size", "4096"],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(conflict.returncode, 0)


if __name__ == "__main__":
    unittest.main()
