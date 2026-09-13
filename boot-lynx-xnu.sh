#!/usr/bin/env bash
# Build a one-shot Android boot image with a linked-in XNU payload.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
UBOOT="${UBOOT:-$HOME/src/u-boot}"
LYNX_BUILD="${LYNX_BUILD:-$UBOOT/build/lynx}"
KERNEL="${KERNEL:-$PWD/kernels/kernel.development.vmapple}"
#
# The EL2 shim services the CPU-service hypercalls, so the kernel is used
# unmodified by default.  Set PATCH_HVC=1 to additionally NOP the initial
# PAC hypercall as a fallback for hosts without EL2.
if [[ "${PATCH_HVC:-0}" == "1" ]]; then
	PATCHED="$PWD/kernels/kernel.development.vmapple.hvc0"
else
	PATCHED="$KERNEL"
fi
AFDT="$ROOT/lynx.afdt"
PAYLOAD="$ROOT/xnu-payload.bin"
OUT="$ROOT/lynx-xnu.img"
EMPTY="$(mktemp)"
trap 'rm -f "$EMPTY"' EXIT

[[ -d "$LYNX_BUILD" ]] || { echo "missing $LYNX_BUILD (run: make O=build/lynx LLVM=1 ARCH=arm google_lynx_defconfig)" >&2; exit 1; }
[[ -f "$KERNEL" ]] || { echo "missing $KERNEL" >&2; exit 1; }

if [[ "${PATCH_HVC:-0}" == "1" ]]; then
	(cd "$ROOT" && go run ./patchvmapple -in "$KERNEL" -out "$PATCHED")
fi
(cd "$ROOT" && go run ./afdt -out "$AFDT")

afdt_offset="$(python3 - "$PATCHED" "$AFDT" "$PAYLOAD" <<'PY'
import sys
from pathlib import Path

kernel = Path(sys.argv[1]).read_bytes()
afdt = Path(sys.argv[2]).read_bytes()
offset = (len(kernel) + 4095) & ~4095
Path(sys.argv[3]).write_bytes(
    kernel + b'\0' * (offset - len(kernel)) + afdt +
    b'XNUAFDT\0' + offset.to_bytes(8, 'little'),
)
print(hex(offset))
PY
)"

echo "AFDT offset: $afdt_offset"
make -C "$UBOOT" O="$LYNX_BUILD" -j"$(nproc)" LLVM=1 ARCH=arm XNU_PAYLOAD="$PAYLOAD"
mkbootimg \
  --kernel "$LYNX_BUILD/u-boot.bin" \
  --ramdisk "$EMPTY" \
  --header_version 4 \
  --pagesize 4096 \
  --cmdline "console=ttySAC0,115200n8 androidboot.hardware=gs201 androidboot.serialconsole=1" \
  --output "$OUT"

# ABL requires an AVB footer even for fastboot boot. This intentionally uses
# the same empty-vbmeta test convention as u-boot/boot-lynx.sh.
python3 - "$OUT" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
img = p.read_bytes()
avbf = img.rfind(b"AVBf")
if avbf != -1 and avbf >= len(img) - 64:
    original = int.from_bytes(img[avbf + 12:avbf + 20], "big")
    if 0 < original <= avbf:
        img = img[:original]

vbmeta = bytearray(256)
vbmeta[:4] = b"AVB0"
vbmeta[4:8] = (1).to_bytes(4, "big")
footer = bytearray(64)
footer[:4] = b"AVBf"
footer[4:8] = (1).to_bytes(4, "big")
footer[12:20] = len(img).to_bytes(8, "big")
footer[20:28] = len(img).to_bytes(8, "big")
footer[28:36] = (256).to_bytes(8, "big")
p.write_bytes(img + vbmeta + footer)
print(f"wrote {p} ({p.stat().st_size} bytes)")
PY

if [[ "${1:-}" == "--build-only" ]]; then
	exit 0
fi

fastboot boot "$OUT"
