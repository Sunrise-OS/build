{
  description = "Linux host tools for building XNU on QEMU";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    msdosfs-src = {
      url = "github:apple-oss-distributions/msdosfs/c9f076c4e7c10b4bc3b0177d114aedf1bb8b9109";
      flake = false;
    };
    hadris-src = {
      url = "github:hxyulin/hadris/d94747a8f859168c0bd7f0af42c0d6eefac9a71b";
      flake = false;
    };
    apfsprogs-src = {
      url = "github:linux-apfs/apfsprogs/3721463ba7f539e532907bc1d10ed5b9a97d0449";
      flake = false;
    };
    firmware-src = {
      url = "git+https://github.com/theo-os/rust-firmware?submodules=1";
      flake = false;
    };
    q1n1-src = {
      url = "github:Sunrise-OS/q1n1/3c0e84ae35315028141a99993b4a0a311a13f9c9";
      flake = false;
    };
    corecrypto-src = {
      url = "github:apple/corecrypto/9612a959abb6eac0aac3ee6a7245c46365c9d81b";
      flake = false;
    };
    pthread-src = {
      url = "github:apple-oss-distributions/libpthread/42d026df5b07825070f60134b980a1ec2552dfee";
      flake = false;
    };
    iostorage-src = {
      url = "github:apple-oss-distributions/IOStorageFamily/7edb88fbae296fb7c8ce2f64e115e116e566d51c";
      flake = false;
    };
    mold-macho-src = {
      url = "github:rui314/mold-macho";
      flake = false;
    };
    xnu-src = {
      url = "github:Sunrise-OS/xnu/54ea37c23af20f9d0354c0d758eb51dc68dbcd81";
      flake = false;
    };
    libdispatch-src = {
      url = "github:swiftlang/swift-corelibs-libdispatch/8a2c456a010d995cfa6a9efada08ea40be46b056";
      flake = false;
    };
    mig-src = {
      url = "github:apple-oss-distributions/bootstrap_cmds/c71d2d72f48995baaea76148f61002e5299841de";
      flake = false;
    };
    iig-src = {
      url = "github:Sunrise-OS/iig-tools/96c1ece6be1ceb6ee2fec6c434d080edc10da2b1";
      flake = false;
    };
    xcbuild-src = {
      url = "github:Sunrise-OS/xcbuild/9fd95496a67731266e7f43fec36a4249ec6f1dec";
      flake = false;
    };
    availability-src = {
      url = "github:apple-oss-distributions/AvailabilityVersions/149b1777f3e8c2133042d8e188f72e3adf6a7110";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      xnu-src,
      libdispatch-src,
      mig-src,
      iig-src,
      xcbuild-src,
      availability-src,
      mold-macho-src,
      corecrypto-src,
      pthread-src,
      iostorage-src,
      firmware-src,
      q1n1-src,
      hadris-src,
      apfsprogs-src,
      msdosfs-src,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      packagesFor =
        system:
        let
          inherit
            (import nixpkgs {
              inherit system;
              # corecrypto's Internal Use License prohibits redistribution.
              config.allowUnfreePredicate =
                pkg:
                builtins.elem (nixpkgs.lib.getName pkg) [
                  "corecrypto-kext"
                  "xnu-kernelcache"
                  "xnu-esp"
                ];
            })
            callPackage
            llvmPackages
            ;
          xnu-build = callPackage ./nix/xnu-build.nix {
            inherit (tools) host-tools mold-macho;
            inherit (llvmPackages) clang llvm;
            compiler-rt-src = llvmPackages.compiler-rt.src + "/compiler-rt";
            inherit libdispatch-src;
            repo = self;
          };
          xnu = callPackage ./nix/xnu.nix {
            inherit xnu-build;
            src = xnu-src;
          };
          kexts = import ./nix/kexts.nix {
            inherit
              callPackage
              xnu
              xnu-src
              corecrypto-src
              pthread-src
              iostorage-src
              msdosfs-src
              ;
            inherit (tools) mold-macho;
            inherit (llvmPackages) clang llvm;
            repo = self;
          };
          boot = import ./nix/boot.nix {
            inherit
              callPackage
              firmware-src
              q1n1-src
              rootfs
              ;
            inherit (llvmPackages)
              clang-unwrapped
              clang
              llvm
              lld
              ;
            inherit (kexts) kernelcache;
            repo = self;
          };
          rootfs-tools = {
            mkapfs = callPackage ./nix/mkapfs.nix { src = apfsprogs-src; };
            apfsck = callPackage ./nix/apfsck.nix { src = apfsprogs-src; };
            hadris-apfs-cli = callPackage ./nix/hadris-apfs-cli.nix { src = hadris-src; };
          };
          apfs-rootfs = callPackage ./nix/rootfs.nix {
            inherit (rootfs-tools) mkapfs apfsck hadris-apfs-cli;
            repo = self;
          };
          pid1 = callPackage ./nix/pid1.nix {
            inherit (llvmPackages) clang llvm;
            inherit (tools) mold-macho;
            repo = self;
          };
          rootfs = callPackage ./nix/fat-rootfs.nix { inherit pid1; };
          tools = import ./nix/host-tools.nix {
            inherit
              callPackage
              xnu-src
              mig-src
              iig-src
              xcbuild-src
              availability-src
              mold-macho-src
              ;
            repo = self;
          };
        in
        tools
        // kexts
        // boot
        // rootfs-tools
        // {
          inherit
            xnu
            rootfs
            apfs-rootfs
            pid1
            ;
          default = tools.host-tools;
        };
    in
    {
      packages = forAllSystems packagesFor;
      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.boot-xnu}/bin/boot-xnu";
        };
        boot-xnu = self.apps.${system}.default;
      });
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
