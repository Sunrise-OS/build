#!/usr/bin/env python3
"""Prelink MH_KEXT_BUNDLE kexts into a classic XNU prelinked kernel.

The kernel's empty __PRELINK_TEXT segment (which has room below __TEXT) receives
the fully linked kexts; __PRELINK_INFO receives the XML dictionary XNU reads in
libsa/bootstrap.cpp. Each kext is linked at its final address here: rebases
become LC_DYSYMTAB local relocations (the form OSKext::slidePrelinkedExecutable
accepts), binds are resolved against the kernel symbol table.

Not done here: corecrypto's FIPS HMAC (__fips_hmacs) is left untouched.
"""
import argparse
import base64
import hashlib
import hmac
import plistlib
import re
import struct
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import escape

PAGE = 0x4000
LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB, LC_DYLD_INFO_ONLY = 0x19, 0x2, 0xB, 0x80000022
MH_KEXT_BUNDLE, MH_EXECUTE = 11, 2
N_STAB, N_TYPE, N_SECT, N_EXT = 0xE0, 0x0E, 0x0E, 0x01
SEG = struct.Struct("<II16sQQQQiiII")      # 72 bytes
SECT = struct.Struct("<16s16sQQIIIIIIII")  # 80 bytes
NLIST = struct.Struct("<IBBHQ")


def align(value, to=PAGE):
    return (value + to - 1) // to * to


class Macho:
    def __init__(self, data, filetype=None):
        self.data = bytearray(data)
        magic, _, _, ftype, self.ncmds, self.sizeofcmds = struct.unpack_from("<6I", data)
        if magic != 0xFEEDFACF:
            raise ValueError("not a 64-bit little-endian Mach-O")
        if filetype is not None and ftype != filetype:
            raise ValueError(f"unexpected Mach-O filetype {ftype}, wanted {filetype}")
        self.cmds = []  # (offset, cmd, size)
        offset = 32
        for _ in range(self.ncmds):
            cmd, size = struct.unpack_from("<II", data, offset)
            if size < 8 or offset + size > 32 + self.sizeofcmds:
                raise ValueError("corrupt load command")
            self.cmds.append((offset, cmd, size))
            offset += size

    def find(self, cmd):
        return [(o, s) for o, c, s in self.cmds if c == cmd]

    def segments(self):
        """Returns [(command offset, name, vmaddr, vmsize, fileoff, filesize, nsects)]."""
        out = []
        for o, _ in self.find(LC_SEGMENT_64):
            _, _, name, vmaddr, vmsize, fileoff, filesize, _, _, nsects, _ = SEG.unpack_from(self.data, o)
            out.append((o, name.rstrip(b"\0").decode(), vmaddr, vmsize, fileoff, filesize, nsects))
        return out

    def sections(self, seg):
        base = seg[0] + SEG.size
        for i in range(seg[6]):
            o = base + i * SECT.size
            yield o, SECT.unpack_from(self.data, o)

    def symbols(self):
        (o, _), = self.find(LC_SYMTAB)
        _, _, symoff, nsyms, stroff, _ = struct.unpack_from("<6I", self.data, o)
        for i in range(nsyms):
            strx, ntype, nsect, ndesc, value = NLIST.unpack_from(self.data, symoff + i * NLIST.size)
            end = self.data.index(b"\0", stroff + strx)
            yield i, self.data[stroff + strx:end].decode(), ntype, value, symoff + i * NLIST.size


def uleb(data, pos):
    result = shift = 0
    while True:
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return result, pos


def sleb(data, pos):
    result = shift = 0
    while True:
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            if byte & 0x40:
                result -= 1 << shift
            return result, pos


def decode_rebases(data, segs):
    """Yields image offsets of 64-bit pointers to rebase."""
    pos, end = 0, len(data)
    address, kind = 0, 1
    while pos < end:
        byte = data[pos]
        pos += 1
        op, imm = byte & 0xF0, byte & 0x0F
        if op == 0x00:
            break
        elif op == 0x10:
            kind = imm
        elif op == 0x20:
            off, pos = uleb(data, pos)
            address = segs[imm][2] + off
        elif op == 0x30:
            off, pos = uleb(data, pos)
            address += off
        elif op == 0x40:
            address += imm * 8
        elif op in (0x50, 0x60, 0x70, 0x80):
            count, skip = imm, 0
            if op in (0x60, 0x80):
                count, pos = uleb(data, pos)
            if op == 0x70:
                skip, pos = uleb(data, pos)
                count = 1
            if op == 0x80:
                skip, pos = uleb(data, pos)
            if kind != 1:
                raise ValueError(f"unsupported rebase type {kind}")
            for _ in range(count):
                yield address
                address += 8 + skip
        else:
            raise ValueError(f"unknown rebase opcode {op:#x}")


def decode_binds(data, segs):
    """Yields (image offset, symbol, addend) for pointer binds."""
    pos, end = 0, len(data)
    address = addend = 0
    symbol, kind = None, 1
    while pos < end:
        byte = data[pos]
        pos += 1
        op, imm = byte & 0xF0, byte & 0x0F
        if op == 0x00:
            continue
        elif op in (0x10, 0x30):
            pass
        elif op == 0x20:
            _, pos = uleb(data, pos)
        elif op == 0x40:
            stop = data.index(b"\0", pos)
            symbol = data[pos:stop].decode()
            pos = stop + 1
        elif op == 0x50:
            kind = imm
        elif op == 0x60:
            addend, pos = sleb(data, pos)
        elif op == 0x70:
            off, pos = uleb(data, pos)
            address = segs[imm][2] + off
        elif op == 0x80:
            off, pos = uleb(data, pos)
            address += off
        elif op in (0x90, 0xA0, 0xB0, 0xC0):
            if kind != 1:
                raise ValueError(f"unsupported bind type {kind}")
            count, skip, step = 1, 0, 8
            if op == 0xA0:
                extra, pos = uleb(data, pos)
                step += extra
            elif op == 0xB0:
                step += imm * 8
            elif op == 0xC0:
                count, pos = uleb(data, pos)
                skip, pos = uleb(data, pos)
                step += skip
            for _ in range(count):
                yield address, symbol, addend
                address += step
        else:
            raise ValueError(f"unsupported bind opcode {op:#x}")


KEXT_LINK_ARGS = ["-arch", "arm64", "-kext", "-no_fixup_chains",
                  "-rename_section", "__TEXT", "__text", "__TEXT_EXEC", "__text",
                  "-rename_section", "__TEXT", "__stubs", "__TEXT_EXEC", "__stubs",
                  "-segprot", "__TEXT", "r--", "r--", "-segprot", "__TEXT_EXEC", "r-x", "r-x"]
# kext segment -> kernel segment holding it (the "new kcgen" split layout)
SPLIT = {"__TEXT": "__PRELINK_TEXT", "__DATA_CONST": "__PLK_DATA_CONST", "__TEXT_EXEC": "__PLK_TEXT_EXEC",
         "__DATA": "__PRELINK_DATA", "__LINKEDIT": "__PLK_LINKEDIT"}


def link_kext(ld, obj, output, addrs=None):
    cmd = [ld, *KEXT_LINK_ARGS]
    for name, addr in (addrs or {}).items():
        cmd += ["-segaddr", name, hex(addr)]
    subprocess.run(cmd + [str(obj), "-o", str(output)], check=True)
    return Macho(Path(output).read_bytes(), MH_KEXT_BUNDLE)


MH_DYLIB_IN_CACHE = 0x80000000


def fips_hmac(kext):
    """Stores corecrypto's integrity HMAC in __fips_hmacs, as its hmacfiletool would.

    fipspost_get_hmac() keys HMAC-SHA256 with 32 zero bytes and hashes the first __text section
    of a __TEXT* segment. For a kext in a cache (MH_DYLIB_IN_CACHE) it reads that section at its
    address rather than at header+offset, which is what lets the split layout work.
    """
    image = kext.data
    if not any(sect[0].rstrip(b"\0") == b"__fips_hmacs" for seg in kext.segments() for _, sect in kext.sections(seg)):
        return  # only corecrypto carries an integrity HMAC
    target = None
    for seg in kext.segments():
        if not seg[1].startswith("__TEXT"):
            continue
        for _, sect in kext.sections(seg):
            if sect[0].rstrip(b"\0") == b"__text" and sect[1].rstrip(b"\0") in (b"__TEXT", b"__TEXT_EXEC"):
                target = (sect[4], sect[3])  # offset, size
                break
        if target:
            break
    if not target or not target[1]:
        raise ValueError("kext has no non-empty __text for the FIPS integrity HMAC")
    digest = hmac.new(bytes(32), bytes(image[target[0]:target[0] + target[1]]), hashlib.sha256).digest()
    slots = [sect for seg in kext.segments() for _, sect in kext.sections(seg)
             if sect[0].rstrip(b"\0") == b"__fips_hmacs"]
    if len(slots) != 1 or slots[0][3] != len(digest):
        raise ValueError("kext needs exactly one 32-byte __fips_hmacs section")
    image[slots[0][4]:slots[0][4] + len(digest)] = digest
    flags, = struct.unpack_from("<I", image, 24)
    struct.pack_into("<I", image, 24, flags | MH_DYLIB_IN_CACHE)


def prelink_kext(kext, kernel_symbols):
    """Fixes up a kext linked at its final split addresses.

    Returns (per-segment bytes {name: bytes}, TEXT size, kmod_info address, rebases, binds).
    """
    segs = kext.segments()
    image = kext.data
    by_name = {s[1]: s for s in segs}
    for name in by_name:
        if name not in SPLIT:
            raise ValueError(f"unexpected kext segment {name}")
    (dyld_o, _), = kext.find(LC_DYLD_INFO_ONLY)
    rebase_off, rebase_size, bind_off, bind_size = struct.unpack_from("<4I", image, dyld_o + 8)
    seg_tuples = [(s[1], 0, s[2]) for s in segs]
    rebases = sorted(set(decode_rebases(bytes(image[rebase_off:rebase_off + rebase_size]), seg_tuples)))
    binds = list(decode_binds(bytes(image[bind_off:bind_off + bind_size]), seg_tuples))

    def file_offset(address):
        for s in segs:
            if s[2] <= address < s[2] + s[3]:
                if address - s[2] >= s[5]:
                    raise ValueError(f"{address:#x} lies in zero-fill")
                return s[4] + address - s[2]
        raise ValueError(f"{address:#x} is outside the kext")

    for address, symbol, addend in binds:
        if symbol not in kernel_symbols:
            raise ValueError(f"kernel does not define {symbol}")
        struct.pack_into("<Q", image, file_offset(address), kernel_symbols[symbol] + addend)
    if {a for a, _, _ in binds} & set(rebases):
        raise ValueError("pointer is both rebased and bound")
    kmod = None
    for _, name, ntype, value, where in kext.symbols():
        if name == "_kmod_info" and ntype & N_TYPE == N_SECT:
            kmod = value
    if kmod is None:
        raise ValueError("kext has no _kmod_info")
    # Pointers already hold final addresses; record them as local relocations
    # (offsets from the first segment, which XNU uses as the reloc base).
    text = by_name["__TEXT"]
    locrel = bytearray()
    for address in rebases:
        locrel += struct.pack("<iI", address - text[2], 3 << 25)
    linkedit = by_name["__LINKEDIT"]
    locrel_off = align(len(image), 8)
    image.extend(b"\0" * (locrel_off - len(image)) + locrel)
    (dy_o, _), = kext.find(LC_DYSYMTAB)
    struct.pack_into("<II", image, dy_o + 72, locrel_off, len(rebases))
    struct.pack_into("<4I", image, dyld_o + 8, 0, 0, 0, 0)
    new_filesize = len(image) - linkedit[4]
    struct.pack_into("<Q", image, linkedit[0] + 32, align(new_filesize))
    struct.pack_into("<Q", image, linkedit[0] + 48, new_filesize)
    fips_hmac(kext)
    # XNU's kalloc_type parsing treats a KCGEN kext as split-segment only if it
    # carries LC_SEGMENT_SPLIT_INFO (an empty one suffices as the marker).
    ncmds, sizeofcmds = struct.unpack_from("<II", image, 16)
    first_content = min(sect[4] for seg in segs for _, sect in kext.sections(seg) if sect[4])
    if 32 + sizeofcmds + 16 > first_content:
        raise ValueError("no room in the kext header for LC_SEGMENT_SPLIT_INFO")
    struct.pack_into("<IIII", image, 32 + sizeofcmds, 0x1E, 16, 0, 0)
    struct.pack_into("<II", image, 16, ncmds + 1, sizeofcmds + 16)
    parts = {}
    for s in kext.segments():
        parts[s[1]] = bytes(image[s[4]:s[4] + s[5]])
    return parts, text[5], kmod, len(rebases), len(binds)


def xnu_plist(value, indent=0):
    pad = "\t" * indent
    if isinstance(value, bool):
        return f"{pad}<{'true' if value else 'false'}/>\n"
    if isinstance(value, int):
        return f'{pad}<integer size="64">{value}</integer>\n'
    if isinstance(value, str):
        return f"{pad}<string>{escape(value)}</string>\n"
    if isinstance(value, bytes):
        return f"{pad}<data>{base64.b64encode(value).decode()}</data>\n"
    if isinstance(value, list):
        return f"{pad}<array>\n" + "".join(xnu_plist(v, indent + 1) for v in value) + f"{pad}</array>\n"
    if isinstance(value, dict):
        body = "".join(f"{pad}\t<key>{escape(k)}</key>\n" + xnu_plist(v, indent + 1) for k, v in value.items())
        return f"{pad}<dict>\n{body}{pad}</dict>\n"
    raise TypeError(type(value))


def load_info_plist(path, substitutions):
    text = Path(path).read_text()
    text = re.sub(r"^\s*<!--.*?-->\s*", "", text, count=1, flags=re.S)
    for key, value in substitutions.items():
        text = text.replace("${%s}" % key, value).replace("$(%s)" % key, value)
    return plistlib.loads(text.encode())


def set_segment(k, seg, vmaddr, data):
    """Points a (previously empty) kernel segment and its one section at `data`."""
    image = k.image
    offset = align(len(image))
    image.extend(b"\0" * (offset - len(image)) + data)
    size = len(data)
    struct.pack_into("<QQQQ", image, seg[0] + 24, vmaddr, align(size), offset if size else 0, size)
    sects = list(k.sections(seg))
    if len(sects) != 1:
        raise ValueError(f"{seg[1]} should have exactly one section")
    o, _ = sects[0]
    struct.pack_into("<QQI", image, o + 32, vmaddr, size, offset if size else 0)


def patch_kernel(kernel_bytes, regions, info_xml):
    """regions maps kernel segment name -> (vmaddr, bytes); returns the new image."""
    k = Macho(kernel_bytes, MH_EXECUTE)
    k.image = k.data
    segs = {s[1]: s for s in k.segments()}
    for name in list(SPLIT.values()) + ["__PRELINK_INFO"]:
        if segs[name][3] or segs[name][5]:
            raise ValueError("kernel is already prelinked")
    for name, (vmaddr, data) in regions.items():
        set_segment(k, segs[name], vmaddr, data)
    set_segment(k, segs["__PRELINK_INFO"], regions["__PRELINK_INFO"][0], regions["__PRELINK_INFO"][1])
    return bytes(k.image)


KPI_PATHS = {
    "com.apple.kpi.bsd": "BSDKernel", "com.apple.kpi.iokit": "IOKit", "com.apple.kpi.libkern": "Libkern",
    "com.apple.kpi.mach": "Mach", "com.apple.kpi.private": "Private", "com.apple.kpi.unsupported": "Unsupported",
    "com.apple.kpi.dsep": "Dsep",
}
CODELESS = 0x7FFFFFFFFFFFFFFF  # kOSKextCodelessKextLoadAddr


def kpi_interfaces(kexts):
    """Codeless OSKernelResource kexts for the com.apple.kpi.* libraries the kexts link against.

    XNU resolves OSBundleLibraries through these; the kernel binary itself provides the symbols
    (they were bound by name above), so they carry no executable. Their version is what
    kexts compare against, so it must be at least what any kext asks for.
    """
    wanted = {}
    provided = {k["CFBundleIdentifier"] for k in kexts}
    for kext in kexts:
        for name, version in kext.get("OSBundleLibraries", {}).items():
            if name in provided:
                continue
            wanted[name] = max(wanted.get(name, "0"), version, key=lambda v: [int(x) for x in v.split(".")])
    result = []
    for name, version in sorted(wanted.items()):
        if name not in KPI_PATHS:
            raise ValueError(f"no provider for library {name}; only com.apple.kpi.* are kernel resources")
        result.append({
            "CFBundleIdentifier": name, "CFBundleName": KPI_PATHS[name] + " Pseudoextension",
            "CFBundlePackageType": "KEXT", "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleExecutable": KPI_PATHS[name],
            "CFBundleVersion": "26.0.0", "OSBundleCompatibleVersion": "1.0",
            "OSKernelResource": True,
            "_PrelinkBundlePath": f"/System/Library/Extensions/System.kext/PlugIns/{KPI_PATHS[name]}.kext",
            "_PrelinkExecutableLoadAddr": CODELESS,
        })
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--ld", default="ld64.mold")
    parser.add_argument("--work", type=Path, required=True, help="scratch directory for kext links")
    parser.add_argument("--kext", action="append", nargs=3, metavar=("OBJECT", "INFO_PLIST", "BUNDLE_NAME"),
                        required=True, help="relocatable kext object, its Info.plist, bundle directory name")
    parser.add_argument("-o", "--output", type=Path, required=True)
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)

    kernel_bytes = args.kernel.read_bytes()
    kernel = Macho(kernel_bytes, MH_EXECUTE)
    symbols = {name: value for _, name, ntype, value, _ in kernel.symbols()
               if not ntype & N_STAB and ntype & N_TYPE == N_SECT and ntype & N_EXT}
    ksegs = {s[1]: s for s in kernel.segments()}

    # Pass 1: sizes. Pass 2 links each kext at its final, split addresses.
    sizes = []
    for obj, _, bundle in args.kext:
        probe = link_kext(args.ld, obj, args.work / (Path(bundle).stem + ".probe"))
        seg = {s[1]: s for s in probe.segments()}
        if seg["__TEXT"][3] != seg["__TEXT"][5]:
            raise ValueError("kext __TEXT must be fully file-backed")
        # LINKEDIT grows by the local relocation table; reserve room for it.
        sizes.append({n: align(seg[n][3] + (0x40000 if n == "__LINKEDIT" else 0)) for n in seg})
    base = ksegs["__PRELINK_TEXT"][2]
    low, cursor = {}, base
    # XNU RWNX-maps everything from the end of PLK_DATA_CONST up to __TEXT after it has mapped
    # PLK_TEXT_EXEC ROX, so DATA_CONST has to be the segment adjacent to __TEXT.
    for name in ("__PRELINK_TEXT", "__PLK_TEXT_EXEC", "__PLK_DATA_CONST"):
        low[name] = cursor
        kext_name = next(k for k, v in SPLIT.items() if v == name)
        cursor += sum(sz[kext_name] for sz in sizes)
    if cursor > ksegs["__TEXT"][2]:
        raise ValueError("kexts do not fit below kernel __TEXT")
    linkedit = ksegs["__LINKEDIT"]
    cursor = linkedit[2] + linkedit[3]
    high = {}
    for name in ("__PRELINK_DATA", "__PLK_LINKEDIT"):
        high[name] = cursor
        kext_name = next(k for k, v in SPLIT.items() if v == name)
        cursor += sum(sz[kext_name] for sz in sizes)
    info_addr = cursor
    placed = {**low, **high}

    regions = {v: bytearray() for v in SPLIT.values()}
    dicts = []
    for (obj, info_path, bundle), sz in zip(args.kext, sizes):
        addrs = {}
        for kext_name, kernel_name in SPLIT.items():
            addrs[kext_name] = placed[kernel_name] + len(regions[kernel_name])
        kext = link_kext(args.ld, obj, args.work / (Path(bundle).stem + ".kext"), addrs)
        parts, text_size, kmod, nrebase, nbind = prelink_kext(kext, symbols)
        # Later kexts may bind to this one (list dependencies first).
        for _, sym, ntype, value, _ in kext.symbols():
            if not ntype & N_STAB and ntype & N_TYPE == N_SECT and ntype & N_EXT:
                symbols.setdefault(sym, value)
        for kext_name, kernel_name in SPLIT.items():
            region = regions[kernel_name]
            if len(region) + len(parts[kext_name]) > len(region) + sz[kext_name]:
                raise ValueError(f"{bundle}: {kext_name} outgrew its reservation")
            region.extend(parts[kext_name])
            region.extend(b"\0" * (sz[kext_name] - len(parts[kext_name])))
        name = bundle.removesuffix(".kext")
        info = load_info_plist(info_path, {"EXECUTABLE_NAME": name, "PRODUCT_BUNDLE_IDENTIFIER":
                                           "com.apple.kec.corecrypto"})
        info.update({
            "_PrelinkBundlePath": f"/System/Library/Extensions/{bundle}",
            "_PrelinkExecutableRelativePath": f"Contents/MacOS/{name}",
            "_PrelinkExecutableLoadAddr": addrs["__TEXT"],
            "_PrelinkExecutableSourceAddr": addrs["__TEXT"],
            "_PrelinkExecutableSize": text_size,
            "_PrelinkKmodInfo": kmod,
        })
        dicts.append(info)
        print(f"{info['CFBundleIdentifier']}: __TEXT {addrs['__TEXT']:#x}, {nrebase} rebases, {nbind} binds, "
              f"kmod_info {kmod:#x}")
    dicts.extend(kpi_interfaces(dicts))
    xml = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
           '<plist version="1.0">\n' + xnu_plist({"_PrelinkInfoDictionary": dicts}) + "</plist>\n")
    final = {name: (placed[name], bytes(data)) for name, data in regions.items()}
    final["__PRELINK_INFO"] = (info_addr, xml.encode() + b"\0")
    out = patch_kernel(kernel_bytes, final, xml)
    args.output.write_bytes(out)
    print(f"wrote {args.output} ({len(out)} bytes)")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        sys.exit(f"prelink-kernelcache: {error!r}")
