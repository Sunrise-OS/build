#!/usr/bin/env bash
set -euo pipefail

export FIRMWARE_DIR=${FIRMWARE_DIR:-$HOME/src/firmware}

pushd $FIRMWARE_DIR && cargo run --release -q -p mkesp -- $HOME/src/q1n1/build/uefi/q1n1.efi /tmp/xnu-esp.img $HOME/src/xnu/BUILD/obj/RELEASE_ARM64_QEMU/kernel.release.qemu=KERNEL /tmp/xnu-esp/AFDT=AFDT && popd

qemu-system-aarch64 \
     -machine virt,acpi=off,gic-version=3 \
     -cpu cortex-a76 \
     -smp 4 \
     -m 4G \
     -accel tcg \
     -device virtio-gpu-rutabaga-pci,gfxstream-vulkan=on,blob=on,hostmem=256M \
     -display none \
     -no-reboot \
     -serial mon:stdio \
     -bios ${FIRMWARE_DIR}/target/tinted-boot-aarch64.bin \
     -drive file=/tmp/xnu-esp.img,if=none,id=esp,format=raw \
     -device virtio-blk-pci,drive=esp -s
