# Python cross-package migration plan

## Goal

Replace Nix as the build/package orchestration layer with a Python package manager and recipe repository inspired by Chimera Linux cports. Recipes are ordinary Python, builds run directly on the host (no sandbox), and cross-compilation is an explicit first-class concept. Preserve the current build graph, source revisions, patches, licensing constraints, and documented bring-up limitations during migration.

This is a staged migration: keep the existing Nix implementation usable until the Python path can reproduce and validate the important outputs. Do not remove Nix or rewrite recipes wholesale as the first step.

## Repository observations

- `flake.nix` composes the graph; `nix/` contains leaf build recipes and graph/group composition.
- `deps/` contains pinned Git submodules for XNU and upstream dependencies. The flake also has pinned source inputs, some of which overlap with submodules or are not represented in `.gitmodules` (for example q1n1, xcbuild, hadris, and apfsprogs).
- Local source and patches are also build inputs: `kernelcache/`, `rootfs/`, `qemu/`, and `patches/`.
- The primary validated build host is `aarch64-linux`; XNU and its kexts target ARM64/QEMU. Host utilities, UEFI firmware, and target binaries require different build/host/target contexts.
- The existing working tree contains substantial staged and unstaged changes across Nix files, source submodules, and documentation. Migration work must preserve those changes and avoid destructive cleanup.
- Corecrypto has restrictive licensing and the resulting combined outputs must not be publicly redistributed. The Python system must carry this metadata and avoid publishing those outputs by default.

## Proposed package model

Use a small Python framework plus a repository of per-package Python recipes (rather than encoding the entire graph in a single script). A recipe should expose declarative metadata and ordinary build/install functions, including:

- package name/version, source URL or local path, pinned revision/checksum, patches, and license/redistribution notes;
- dependencies split at least into build-host tools, target/runtime dependencies, and build-only dependencies;
- supported build/host/target triples and the required cross toolchain;
- configure/build/check/install steps, expected outputs, and environment overrides.

The runner should provide dependency resolution, topological ordering, build plans/dry runs, logs, failure propagation, and a CLI for inspecting/building packages. It should use explicit build and staging directories, but run commands as the invoking user without a sandbox. Paths, environment, and toolchain selection should be visible and overridable. The runner must not imply that unsandboxed execution is hermetic.

For cross compilation, distinguish:

- **build**: machine running the package manager and build tools;
- **host**: machine/OS on which a built utility will run (important for tools executed during the build);
- **target**: machine/ABI the produced compiler output or kernel artifact targets.

For the first milestone, validate Linux build hosts and the existing ARM64 XNU/QEMU target. Keep triples and toolchain configuration general; defer claims of Linux-to-macOS or other multi-OS cross builds until recipes and toolchains are validated. Support native host utilities as build dependencies independently from ARM64 target artifacts.

## Package graph inventory

This inventory is derived from the Nix composition files and README. It is a migration map, not a complete extraction of every shell command or implicit upstream dependency; recipe conversion must inspect each `.nix` implementation and current build scripts.

| Group | Packages / outputs | Important relationships and notes |
|---|---|---|
| Host toolchain | `mig`, `iig`, `plutil`, `availability`, `mold-macho`, `host-tools` | Host executables; `host-tools` aggregates tools. `mig` depends on XNU source/headers and host compiler tools; `plutil` comes from xcbuild; linker supports Mach-O/kext work. |
| XNU | `xnu`, `xnu.headers` | Cross-builds XNU for ARM64/QEMU; consumes host tools, LLVM/clang, compiler-rt sources, and libdispatch. Exposes kernel and a separate headers/build-metadata output used by kext packages. |
| Kext toolchain and kexts | `kext-compiler`, `corecrypto`, `pthread`, `iostorage`, `msdosfs`, `security-stub`, `platform-expert`, `arm-cpu`, `virtio-blk` | Kexts depend on XNU headers/config and cross compiler/linker. `virtio-blk` consumes IOStorage; some local kexts use shared repo sources. Corecrypto license restrictions are critical. IOStorage supplies headers as well as a kext. |
| Kernelcache | `kernelcache` | Combines kext objects and metadata, performs prelinking and corecrypto integrity handling; produces boot kernelcache. Depends on XNU and the selected kext set. |
| Firmware/boot | `mkesp`, `mkimage`, `firmware`, `q1n1`, `afdt`, `esp`, `boot-xnu` | Host image-building tools plus ARM64 UEFI firmware/loader and boot assets. Firmware uses Rust and multiple targets; `esp` composes loader, kernelcache, and device tree. `boot-xnu` also invokes host QEMU and configures runtime environment. |
| Root filesystem | `pid1`, `rootfs`, `mkapfs`, `apfsck`, `hadris-apfs-cli`, `apfs-rootfs` | PID1 is an ARM64 target executable; FAT/APFS image construction uses host utilities. APFS outputs are experimental and filesystem support is not integrated into XNU VFS. Preserve README's current boot/status caveats. |
| Aggregate/defaults | `default`, `packages`, runnable app | Flake-level system matrices and composition are replaced by explicit Python build/target configuration and CLI targets, not by one giant package. |

### Source/patch inputs to track

Known source inputs include XNU, bootstrap_cmds/MIG, iig-tools, xcbuild, AvailabilityVersions, mold-macho, corecrypto, libpthread, IOStorageFamily, msdosfs, libdispatch, firmware (with submodules), q1n1, OpenSSL, Hadris, and apfsprogs. Local sources include kernelcache drivers/stubs, rootfs helpers, QEMU utilities, and the tracked `patches/`. Establish one authoritative pin for each package and document when a submodule is the source checkout versus when a separate URL/revision is needed. Preserve firmware submodule fetch behavior and patch application order.

## Migration phases and acceptance criteria

### 0. Baseline and source accounting

- Record current build commands, outputs, source revisions, patches, licenses, and host/target assumptions from all recipes and scripts.
- Confirm submodule state and identify any flake inputs that are absent from `deps/`.
- Keep user changes intact; do not reset or clean the worktree.
- Acceptance: package/source inventory can identify every flake package output and its direct inputs.

### 1. Python package-manager skeleton

- Add a Python CLI and recipe interface, configuration for build/host/target triples, and a local build root/cache layout.
- Implement metadata inspection, dependency graph validation, topological plans, and dry-run output before executing arbitrary recipe build steps.
- Clearly state that builds are unsandboxed; do not promise reproducibility from pinned sources alone.
- Acceptance: unit tests cover dependency ordering, cycles/missing dependencies, target compatibility, and dry-run output; no project build has been migrated yet.

### 2. Prove the recipe model

- Port one small host tool package (a minimal build with low dependency count) and one local ARM64 target artifact such as the existing PID1/rootfs helper.
- Add explicit toolchain/environment injection, command logging, staging installation, and output path reporting.
- Compare resulting files/behavior with the existing build path where practical.
- Acceptance: both recipes build from a clean package build directory on the documented host; target architecture is checked; Nix remains functional.

### 3. Host tools and XNU

- Port host utilities individually, then package the host-tool aggregate.
- Port XNU and headers with explicit LLVM/compiler-rt, MIG, IIG, libdispatch, and target settings.
- Preserve the split outputs required by kext consumers.
- Acceptance: reproduce the ARM64/QEMU kernel and headers outputs and validate downstream header paths.

### 4. Kexts and kernelcache

- Port the shared kext compiler configuration and then individual kext recipes, encoding dependency distinctions and license metadata.
- Port kernelcache linking/prelinking and integrity steps.
- Acceptance: create a usable kernelcache; restricted artifacts are marked non-redistributable and publishing is opt-in.

### 5. Firmware, images, and launch workflow

- Port Rust firmware/loader builds, image tools, AFDT/ESP composition, rootfs tools, and QEMU launcher.
- Keep build-host tools separate from ARM64 outputs and handle firmware's Rust targets/submodules explicitly.
- Acceptance: Python-managed full chain reaches the same documented boot state as the existing chain; don't claim fixes for known root-filesystem/kernel bring-up blockers.

### 6. Cutover and Nix retirement

- Update documentation and CI/workflows to use the Python manager, retain a transition period with both paths, then remove Nix only after parity and user approval.
- Acceptance: clean documented setup builds supported outputs without Nix; package graph, licenses, source pins, and known limitations are documented; no untracked reliance on ambient host packages remains unexplained.

## Risks and design constraints

- Unsandboxed recipes can read/write outside their build tree. Use dedicated directories, log exact commands and environment, and make destructive operations opt-in; this is operational hygiene, not isolation.
- Cross-compilation correctness depends on correct compiler, binutils, sysroot/SDK, Rust target, and build-vs-host tool selection. Require explicit configuration and fail early for unsupported triples.
- Git submodule pins and flake source pins can diverge. Make the source of truth explicit and validate revisions.
- Some current derivations consume nixpkgs packages or source trees (LLVM/compiler-rt, Rust std sources, host utilities). Replacing these requires a documented external toolchain strategy; don't silently assume a distribution's versions are equivalent.
- License flags and non-redistribution restrictions must follow package dependencies into aggregate outputs.
- Existing worktree changes are user-owned context; migration should be incremental and never use reset/clean operations.
