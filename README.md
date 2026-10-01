# XNU build tools

This repository provides Linux host tools and scripts for building an ARM64/QEMU XNU kernel.

## Nix host tools

The Nix packages cover host tools, XNU and its headers, kexts, a prelinked kernelcache, UEFI firmware, the loader, and a bootable ESP image. A packaged QEMU launcher is available via `nix run`.

```sh
nix build .#host-tools
nix build .#mig
nix build .#iig
nix build .#plutil
nix build .#availability
nix build .#mold-macho
```

`flake.nix` uses nixpkgs master and declares systems via `nixpkgs.lib.genAttrs`. All source inputs are pinned by revision in `flake.lock`. The package outputs are available under `packages.<system>`.

Each tool has its own derivation in `nix/`: `mig.nix`, `iig.nix`, `plutil.nix`, `availability.nix`, and `mold-macho.nix`. `host-tools.nix` only composes the packages, while `toolchain.nix` assembles their outputs. Derivations take explicit dependencies through `callPackage`, not a generic package-set argument.

The linker source is `github:rui314/mold-macho/pull/35/head`, pinned by the lock file. Both `mold` and `ld64.mold` are installed. Upstream linker integration tests are disabled because they need an external Darwin SDK/toolchain.

The host-tool builds have been tested on `aarch64-linux`; other declared systems are not build-validated yet.

## XNU kernel and headers

```sh
nix build .#xnu
nix build .#xnu.headers --out-link result-headers
```

`xnu` is a multi-output derivation. Its default `out` output contains
`boot/kernel.release.qemu`; `xnu.headers` contains:

- Installed public and private headers under
  `System/Library/Frameworks/Kernel.framework/Versions/A/{Headers,PrivateHeaders}`.
- Raw exports under `BUILD/obj/EXPORT_HDRS` and libkern build configuration under
  `BUILD/obj/RELEASE_ARM64_QEMU/libkern/RELEASE` for kext builders.
- `EXTERNAL_HEADERS` from the pinned XNU source.

Downstream derivations can depend directly on `xnu.headers`. Both outputs are built
in one sandboxed invocation. `nix/xnu.nix` defines the outputs and installation;
`nix/xnu-build.nix` defines the explicit build tools and QEMU make flags. Compiler-rt
profile sources come from the locked nixpkgs LLVM package. Constructor pointers
are preserved with `-no_fixup_chains` for XNU's C++ runtime.

Kernel builds are supported on Linux; Darwin remains declared for existing host
packages, not for XNU. The complete build and QEMU boot chain have been tested on
`aarch64-linux`; builds and booting on other systems have not been validated.

## Root filesystem bring-up

`nix build .#rootfs` builds a disposable FAT32 root image containing a syscall-only
ARM64 Mach-O at `/sbin/launchd`; `nix run .#boot-xnu` attaches it as a separate,
read-only virtio-MMIO disk while preserving the PCI ESP. q1n1 is built with a
root-specific boot argument (`rd=disk0`), and AFDT omits the 4 KiB placeholder
ramdisk for this mode. The APFS formatter/checker and Hadris inspector remain
available as `.#mkapfs`, `.#apfsck`, `.#hadris-apfs-cli`, and `.#apfs-rootfs`;
APFS support is not yet connected to XNU's VFS.

Apple msdosfs is registered after BSD vnode operations initialize, via the
`IOBSD` resource, and can mount the root read-only. Rootauth is deliberately
bypassed only for a QEMU ARM64 build and only on a read-only root vnode. **This is
not authentication and does not verify the FAT image.** The existing security
stub is also non-enforcing. These paths are emulator bring-up only.

The FAT volume mounts, but the static PID 1 has not yet been confirmed executing
in userspace. That is the current blocker; the image currently provides the
minimal `/sbin/launchd` test program, not a general userspace distribution.

## Kexts and kernelcache

```sh
nix build .#kernelcache
nix build .#pthread .#iostorage .#virtio-blk
```

`kernelcache` installs `boot/kernelcache`. Each kext is a separate derivation:
`corecrypto`, `pthread`, `iostorage`, `security-stub`, `platform-expert`, `arm-cpu`,
and `virtio-blk`. Each provides `kext.o` and `Info.plist` for the prelinker.
IOStorageFamily also provides its headers under `include/IOKit/storage`.
`nix/kexts.nix` composes these packages; `nix/kext-compiler.nix` shares compilation
flags without sharing the builds. The prelinker resolves inter-kext imports,
keeps the split-segment layout, and patches corecrypto's integrity HMAC.

**Licensing and security:** corecrypto's Internal Use License restricts usage and
prohibits redistribution. Corecrypto, the combined kernelcache, and the ESP are
marked unfree with Hydra builds disabled. The flake permits only these named
unfree packages; it does not enable all unfree packages. Do not upload these
artifacts to public binary caches. The security stub enforces nothing, and the
IOStorageFamily DriverKit shim is not DriverKit support: these are emulator
bring-up artifacts, not production security or driver implementations.

## Firmware, ESP and QEMU

```sh
nix build .#mkesp             # result/bin/mkesp
nix build .#firmware          # result/share/firmware/tinted-boot-aarch64.bin
nix build .#q1n1              # result/EFI/BOOT/BOOTAA64.EFI
nix build .#esp               # result/xnu-esp.img
nix run                      # same as nix run .#boot-xnu
nix run .#boot-xnu -- -s      # optional QEMU gdbstub
```

The firmware source is a pinned published commit with its Patina submodules.
Its tracked patches are applied in the sandbox. The firmware uses nixpkgs Rust
with offline `build-std` for `aarch64-unknown-none` and `aarch64-unknown-uefi`;
there is no rustup or rust-overlay dependency. `mkesp` and `mkimage` are separately
packaged host tools. The ESP contains q1n1, the kernelcache as `KERNEL`, and the
QEMU device tree as `AFDT`. `nix/boot.nix` only composes their derivations.

The launcher uses TCG, four Cortex-A76 CPUs, 4 GiB RAM, GICv3, a rutabaga GPU,
virtio RNG, and a PCI ESP device. QEMU's snapshot mode protects the store image
from writes. Additional arguments are passed to QEMU. Mesa's default bundled
Vulkan ICD is `lvp` on Linux and `kosmickrisp` on Darwin, checked at runtime rather
than assumed present. Override it with `VK_DRIVER_FILES=/path/to/icd.json` if
needed. The Darwin selection is not a claim that the complete pipeline builds
or runs there yet.

**Current boot limit:** the packaged chain boots XNU and passes corecrypto's FIPS
self-tests, then reaches BSD root setup. There is no real root filesystem: the
AFDT describes a 4096-byte placeholder ramdisk. The virtio-blk kext probes MMIO,
while the ESP is attached through PCI, so it reports no matching device and root
mounting fails. Root-disk wiring and filesystem bring-up are separate work.

## Python cross-package prototype

The unsandboxed package manager uses Python recipes and a **PyO3/petgraph Rust dependency resolver**. It supports recipe listing, dependency-ordered plans, target checks, dry runs, and staged outputs. Rust dependencies are locked in `Cargo.lock`; Rust 1.99.0 is specified in `rust-toolchain.toml`.

```sh
# Bootstrap requires Python 3.11+, uv, Git, tar/xz/zstd, sh,
# a native linker/libc or macOS SDK, and network access.
sh scripts/bootstrap.sh
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python -m crosspkg list
.venv/bin/python -m crosspkg build availability-pl
.venv/bin/python -m crosspkg --target aarch64-apple-macos15 plan bringup-pid1
.venv/bin/python -m crosspkg --target aarch64-apple-macos15 build bringup-pid1
```

The bootstrap script downloads Rust 1.99.0 directly from `static.rust-lang.org`, verifies its SHA-256, installs it into `.crosspkg/packages/rust-1.99.0`, and builds the Python extension. No rustup is required. Build hosts are restricted to ARM64 Linux and ARM64 macOS; only Linux is build-tested.

The PID 1 recipe depends on packages, not ambient executable discovery:

- `llvm`: the supplied LLVM 23.1.2 host archive, verified against its published SHA-256;
- `rust`: Rust 1.99.0 from the official distribution archive;
- `mold-macho`: source-built from `https://github.com/rui314/mold-macho` at a pinned commit using packaged Rust/LLVM and upstream `Cargo.lock`;
- `bootstrap-python`: explicitly exposes the invoking Python interpreter as a bootstrap exception.

Mach-O linking uses packaged `ld64.mold`, not LLVM's Mach-O linker. Recipe commands run with a controlled environment and a `PATH` containing dependency package outputs only. Bootstrap downloads, source checkout, archive extraction, and installation use host tools explicitly. Downloads and package/work directories live under `.crosspkg/`; LLVM decompression can require approximately 1 GiB of decoder memory.

**Hermeticity limits:** these builds are not sandboxed or fully hermetic. Host libc/headers/SDK, the bootstrap Python installation, and network access for locked Cargo dependencies are still external inputs. Toolchain pinning alone does not prevent host filesystem access or guarantee reproducibility. There is no package cache/invalidation model yet; builds reinstall their dependencies. `availability-pl` still uses the existing `tools-src/AvailabilityVersions` checkout with a checked Git revision; local PID 1 sources are explicitly unpinned. This does not replace Nix yet. See `MIGRATION_PLAN.md` for the migration stages.

## Existing build workflow

`build_xnu.sh` builds XNU and its host tools using local sibling checkouts. See the script's usage and environment overrides for its current workflow.
