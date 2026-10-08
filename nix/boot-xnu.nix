{
  lib,
  stdenv,
  writeShellApplication,
  qemu,
  mesa,
  vulkan-loader,
  firmware,
  esp,
  rootfs ? null,
}:
let
  icdName = if stdenv.hostPlatform.isDarwin then "kosmickrisp" else "lvp";
  libraryPathVar =
    if stdenv.hostPlatform.isDarwin then "DYLD_FALLBACK_LIBRARY_PATH" else "LD_LIBRARY_PATH";
in
writeShellApplication {
  name = "boot-xnu";
  runtimeInputs = [ qemu ];
  text = ''
    # Mesa's Vulkan drivers differ by platform. Do not assume lavapipe exists.
    if [ -z "''${VK_DRIVER_FILES:-}" ]; then
      shopt -s nullglob
      icds=(${mesa}/share/vulkan/icd.d/${icdName}_icd*.json)
      if [ "''${#icds[@]}" -ne 1 ]; then
        echo "Mesa does not provide a unique ${icdName} ICD; set VK_DRIVER_FILES explicitly." >&2
        exit 1
      fi
      export VK_DRIVER_FILES="''${icds[0]}"
    fi
    export ${libraryPathVar}="${
      lib.makeLibraryPath [ vulkan-loader ]
    }''${${libraryPathVar}:+:$${libraryPathVar}}"
    exec qemu-system-aarch64 \
      -machine virt,acpi=off,gic-version=3 -cpu cortex-a76 -smp 4 -m 4G -accel tcg \
      -device virtio-gpu-rutabaga-pci,gfxstream-vulkan=on,blob=on,hostmem=256M \
      -display none -no-reboot -serial mon:stdio \
      -bios ${firmware}/share/firmware/tinted-boot-aarch64.bin \
      -drive file=${esp}/xnu-esp.img,if=none,id=esp,format=raw,snapshot=on \
      -object rng-random,id=hostrng,filename=/dev/urandom -device virtio-rng-pci,rng=hostrng \
      -device virtio-blk-pci,drive=esp \
      ${
        lib.optionalString (rootfs != null) ''
          -global virtio-mmio.force-legacy=false \
          -drive file=${rootfs}/rootfs.img,if=none,id=rootfs,format=raw,readonly=on \
          -device virtio-blk-device,drive=rootfs \
        ''
      }"$@"
  '';
}
