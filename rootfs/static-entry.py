#!/usr/bin/env python3
"""Convert a dependency-free ARM64 Mach-O LC_MAIN to LC_UNIXTHREAD.

XNU delegates LC_MAIN entry handling to dyld. A syscall-only binary instead
needs an ARM_THREAD_STATE64 entry. Preserve file/VM offsets and regenerate the
existing ad-hoc CodeDirectory page hashes after changing the header.
"""
import hashlib
from pathlib import Path
import struct
import sys


def convert(source):
    data = bytearray(source)
    magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cpu != 0x100000C or kind != 2:
        raise ValueError("Expected an ARM64 Mach-O executable")
    commands = []
    cursor = 32
    entry = None
    text = None
    signature = None
    first_section = len(data)
    for _ in range(count):
        cmd, length = struct.unpack_from("<II", data, cursor)
        if length < 8 or length % 8 or cursor + length > 32 + size:
            raise ValueError("Invalid load command")
        payload = bytes(data[cursor:cursor + length])
        if cmd in (0xC, 0xE, 0x18 | 0x80000000, 0x1F | 0x80000000):
            raise ValueError("Static binary must have no dynamic dependencies")
        if cmd == 0x19:
            name = payload[8:24].rstrip(b"\0")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<4Q", payload, 24)
            if name == b"__TEXT":
                text = vmaddr, fileoff, filesize
            sections, = struct.unpack_from("<I", payload, 64)
            for index in range(sections):
                offset, = struct.unpack_from("<I", payload, 72 + index * 80 + 48)
                if offset:
                    first_section = min(first_section, offset)
        if cmd == 0x80000028:
            if entry is not None:
                raise ValueError("Duplicate LC_MAIN")
            entry, = struct.unpack_from("<Q", payload, 8)
            payload = None
        elif cmd == 0x1D:
            signature = struct.unpack_from("<II", payload, 8)
        commands.append(payload)
        cursor += length
    if cursor != 32 + size or entry is None or text is None or signature is None:
        raise ValueError("Missing LC_MAIN, __TEXT or ad-hoc signature")
    base, fileoff, filesize = text
    if not fileoff <= entry < fileoff + filesize:
        raise ValueError("Entry is outside __TEXT")
    state = bytearray(272)
    struct.pack_into("<Q", state, 256, base + entry - fileoff)
    thread = struct.pack("<4I", 5, 288, 6, 68) + state
    header_commands = b"".join(thread if payload is None else payload for payload in commands)
    if 32 + len(header_commands) > first_section:
        raise ValueError("Insufficient header padding; link with -headerpad 0x400")
    data[32:32 + len(header_commands)] = header_commands
    struct.pack_into("<I", data, 20, len(header_commands))
    # No dyld binding or two-level namespace is needed for this binary.
    struct.pack_into("<I", data, 24, flags & ~(4 | 128))

    sigoff, sigsize = signature
    magic, blobsize, blobs = struct.unpack_from(">3I", data, sigoff)
    if magic != 0xFADE0CC0 or blobsize > sigsize:
        raise ValueError("Invalid signature superblob")
    found = False
    for index in range(blobs):
        slot, relative = struct.unpack_from(">2I", data, sigoff + 12 + index * 8)
        start = sigoff + relative
        blobmagic, length = struct.unpack_from(">2I", data, start)
        if blobmagic != 0xFADE0C02:
            continue
        _, _, version, csflags, hashoff, identoff, special, pages, limit = struct.unpack_from(">9I", data, start)
        hashsize, hashtype, platform, pageshift = struct.unpack_from("4B", data, start + 36)
        if not csflags & 2 or special != 0 or hashsize != 32 or hashtype != 2:
            raise ValueError("Only plain SHA256 ad-hoc CodeDirectories are supported")
        pagebytes = 1 << pageshift
        if limit != sigoff or pages != (limit + pagebytes - 1) // pagebytes:
            raise ValueError("Unexpected code limit or page count")
        if start + length > sigoff + sigsize or hashoff + pages * hashsize > length:
            raise ValueError("Signature hash table is out of bounds")
        for page in range(pages):
            begin = page * pagebytes
            digest = hashlib.sha256(data[begin:min(begin + pagebytes, limit)]).digest()
            dest = start + hashoff + page * hashsize
            data[dest:dest + hashsize] = digest
        found = True
    if not found:
        raise ValueError("No CodeDirectory")
    return bytes(data)


if __name__ == "__main__":
    source, dest = map(Path, sys.argv[1:])
    dest.write_bytes(convert(source.read_bytes()))
