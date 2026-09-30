#!/usr/bin/env bash
set -euo pipefail

export FIRMWARE_DIR=${FIRMWARE_DIR:-$HOME/src/firmware}

XNU_ESP_DIR=${XNU_ESP_DIR:-/tmp/xnu-esp}
KERNEL=$HOME/src/xnu/BUILD/obj/RELEASE_ARM64_QEMU/kernel.release.qemu
# build_xnu.sh produces the corecrypto-prelinked kernel when a corecrypto checkout exists
[ -s "$XNU_ESP_DIR/kernelcache" ] && KERNEL=$XNU_ESP_DIR/kernelcache

pushd $FIRMWARE_DIR && cargo run --release -q -p mkesp -- $HOME/src/q1n1/build/uefi/q1n1.efi /tmp/xnu-esp.img $KERNEL=KERNEL /tmp/xnu-esp/AFDT=AFDT && popd

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
     -object rng-random,id=hostrng,filename=/dev/urandom \
     -device virtio-rng-pci,rng=hostrng \
     -device virtio-blk-pci,drive=esp -s
