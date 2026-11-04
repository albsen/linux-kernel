{
  description = "Lenovo ThinkPad T14s (Snapdragon X Elite) — Linux 7.3.0-jg-5 EL2 kernel for NixOS";

  # NixOS 26.11 is built from nixpkgs-unstable; pin to master for the toolchain
  # (Rust 1.99, LLVM/Clang 21.1.8, flex 2.6.4, bison 3.8.2, pahole 1.32).
  # The exact revision is locked in flake.lock (committed).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/master";

  outputs = { self, nixpkgs }:

  let
    system = "aarch64-linux";

    pkgs = import nixpkgs {
      inherit system;
      # Native aarch64-linux build: the agent runs ON the target arm64 laptop.
      overlays = [ ];
    };

    # The kernel source tree is this repository itself (full clone of jglathe's
    # 7.3.0-jg-5, see nixos/upstream.md). Building from `./` keeps the result a
    # self-contained, full-history source — not a reference to an external repo.
    kernelSrc = ./.;

    # Migrated working-EL2 kernel configuration (Phase 5): the 7.0.12 working
    # config run through the 7.3 `olddefconfig`, with Rust preserved.
    configfile = ./nixos/working_el2-7.3.config;

    # Full build dependency set (brief §Phase 6 "Required build dependencies").
    # All attr names verified to exist in the pinned nixpkgs.
    buildDeps = with pkgs; [
      # C compiler / LLVM
      gcc                      # GNU C (fallback; the build uses Clang via LLVM=1)
      clang                    # Clang 21.1.8 (primary, LLVM=1)
      pkgs.llvmPackages_21.llvm   # LLVM 21.1.8
      pkgs.llvmPackages_21.lld    # LLD (ld.lld)
      # Build tools
      binutils
      pkg-config
      bc
      # Kconfig
      flex                     # 2.6.4
      bison                    # 3.8.2
      # Scripting
      python3
      perl
      bash
      # Device trees
      dtc
      # Debug metadata / ELF
      pahole                   # dwarves/pahole 1.32 (provides `pahole` on PATH)
      elfutils
      # Cryptography
      openssl
      # Kernel utilities
      kmod
      cpio
      # General tools
      rsync
      file
      gzip
      xz
      zstd
      bzip2
      gnutar
    ];

    # The kernel's CONFIG_RUST=y needs the Rust toolchain. nixpkgs' kernel
    # builder (pkgs/top-level/linux-kernels.nix → os-specific/linux/kernel/
    # build.nix) already wires these in when `withRust` is true:
    #     rustc-unwrapped, rust-bindgen-unwrapped, rustPlatform.rustLibSrc
    # so `nix build .#kernel` needs no extra work. We mirror the same set in the
    # devShell so the manual `make O=… LLVM=1 olddefconfig / rustavailable` path
    # behaves identically to the Nix build.
    rustToolchain = with pkgs; [
      rustc-unwrapped
      rust-bindgen-unwrapped
    ];

    # devShell for `nix develop` + manual `make O=… LLVM=1 olddefconfig /
    # rustavailable` (brief §Phase 6 "Validate the development shell").
    devShell = pkgs.mkShell {
      packages = buildDeps ++ rustToolchain;
      # Point the kernel build at the Rust std-lib source (RUST_LIB_SRC) and
      # libclang (LIBCLANG_PATH for bindgen). Same values the Nix build uses.
      RUST_LIB_SRC = builtins.toString pkgs.rustPlatform.rustLibSrc;
      LIBCLANG_PATH = builtins.toString pkgs.libclang;
      # LLVM=1 forces the Clang/LLD path (matches the running kernel's build);
      # ARCH=arm64 is native (this is the target machine).
    };

    linuxKernel = pkgs.linuxPackagesFor (pkgs.linuxManualConfig {
      src = kernelSrc;
      version = "7.3.0";
      pname = "linux-t14s";
      modDirVersion = "7.3.0";
      configfile = configfile;
      # No ported 7.0.12 patches: the 7.3 jglathe tree already contains the
      # equivalent EL2 work (see nixos/patch-reference.md).
      kernelPatches = [ ];
    });

  in
  {
    packages.${system} =
      {
        inherit (linuxKernel) kernel;
        default = linuxKernel.kernel;
        # Raw toolchain set, for convenience / inspection.
        toolchain = pkgs.buildEnv {
          name = "t14s-kernel-toolchain";
          paths = buildDeps ++ rustToolchain;
        };
      };

    devShells.${system}.default = devShell;
  };
}
