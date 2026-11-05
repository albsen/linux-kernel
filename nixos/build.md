# Build (Phase 6–7)

The Linux 7.3.0-jg-5 kernel for the T14s, built **natively** (on the T14s,
aarch64) through the project flake. This document records what was built,
with which toolchain, and how it maps to a NixOS deployment.

Related: `config-migration.md` (the config), `upstream.md` (the repo),
`el2-verification.md` (boot test), `maintenance-workflow.md` (rebase).

## 1. How to build it

```sh
cd kernel_7.3.x/t14s_linux_kernel

# G1 — flake + devShell evaluate (no build)
nix flake check . --no-build

# G2 — Kconfig self-consistent AND Rust available (inside the devShell)
nix develop .#default --command \
  bash -c 'make O=$PWD/.build ARCH=arm64 LLVM=1 olddefconfig && \
            make O=$PWD/.build ARCH=arm64 LLVM=1 rustavailable'
#   → "Rust is available!"

# G3 — full native build (Image + modules + dtbs)
nix build .#kernel -L --max-jobs 2
```

`nix build .#kernel` evaluates `packages.aarch64-linux.kernel`
(= the `linuxManualConfig` **kernel** derivation, *not* the full attrset) and
produces a single store path. `--max-jobs 2` is the **sustainable** job count
on this machine — see §3.

**Result (this build):**

```
/nix/store/fkd3vg51kpqcdvhlrwl12jxpp81gswwl-linux-t14s-7.3.0
├── Image            44,141,056 bytes   (arm64, ELF magic `4d 5a 40 fa`)
├── System.map       10,372,710 bytes
└── dtbs/
    ├── qcom/…       441 .dtb total
    │   ├── x1e78100-lenovo-thinkpad-t14s.dtb
    │   ├── x1e78100-lenovo-thinkpad-t14s-el2.dtb
    │   ├── x1e78100-lenovo-thinkpad-t14s-oled.dtb
    │   └── x1e78100-lenovo-thinkpad-t14s-oled-el2.dtb   ← the EL2 one
    └── bst/…
<separate output>
/nix/store/skap94a5kzf563n29k4k9fvfaim1d4bz-linux-t14s-7.3.0-modules
└── lib/modules/7.3.0/…   6251 *.ko*
```

So the three Phase-6 targets are all present: **`Image`, `modules` (6251),
and the `x1e78100-…-oled-el2.dtb`.** The `linuxPackagesFor` attrset (flaked as
`.linuxPackages`) additionally carries `dev` (vmlinux/BTF), `modules`,
`systemd`, `ebpf-headers`, and one derivation per module — see §5.

## 2. Toolchain (pinned in `flake.lock`)

The flake pins `inputs.nixpkgs` to **`github:NixOS/nixpkgs/master`** (a
2026‑11‑04 master, matching the running NixOS 26.11). The build used:

| Tool | Version |
|---|---|
| clang / lld / llvm | 21.1.8 |
| rustc | **1.99.0** |
| bindgen | 0.72.1 |
| pahole (dwarves) | 1.32 |
| flex / bison | 2.6.4 / 3.8.2 |
| dtc | 1.8.1 |
| gcc (host tools only) | 16.2.0 |

`LLVM=1` forces the Clang/LLD compiler path (matches the running 7.0.12
kernel, which was also a Clang build). `CONFIG_RUST=y` is satisfied by
`rustc 1.99` + `RUST_LIB_SRC`/`KRUSTFLAGS` wired by nixpkgs' own
`build.nix` — the flake does **not** add a separate Rust path.

## 3. The `-j` fan-out problem (why `--max-jobs 2`, and why it still mattered)

This is the non-obvious part, so it's documented.

- Nix's `--max-jobs` limits **parallel *derivations***, not compiler
  processes. But it does set `NIX_BUILD_CORES = nproc` by default, which the
  kernel's top-level `make` turns into `make -j$(nproc)` = **`-j12`**.
- The kernel Makefile then recurses (`$(MAKE) -C dir …`). Because the parent
  exports an *empty* `MAKEFLAGS`, the sub-makes do **not** share the parent
  jobserver — each directory fans out on its own. Net effect: **12 `cc1plus`
  at once**, all 12 cores, regardless of the Nix `-j` you pass.
- On this T14s the 12-way compile draws a sustained **−12…−26 W** from the
  battery (the ~40 W USB-C input covers it on average, but compile *bursts*
  dip the battery). A 12-core build is **not** battery-sustainable.

**Fix applied:** run the whole build pinned to 2 cores:

```sh
taskset 0x3 nix build .#kernel -L --max-jobs 2
```

`taskset 0x3` pins the entire process tree (make + every `cc1plus`) to CPU
0–1, so the fan-out cannot exceed 2 cores no matter how the Makefile
misbehaves. `--max-jobs 2` is then just belt-and-suspenders. With this, the
build **charged the battery from ~50% to ~94%** while compiling — i.e. the
net power is positive and it's safe to run unattended.

> `nix.conf` on this box is set to `max-jobs = 2` so that *any* Nix command
> (including a stray `nix build`) stays in that envelope by default.
> `taskset` is the actual hard cap; Nix alone can't provide one here
> (this sandbox has no `--cores` flag, no writable cgroup, and runs in a
> separate PID namespace from the host).

## 4. What was *not* changed (and what was)

- **Kernel source: zero local patches** (`kernelPatches = [ ]`). The jglathe
  7.3 tree already carries the EL2 DTS work; see `patch-reference.md`.
- **Config: one deliberate change** vs the 7.0.12 working config —
  `CONFIG_NETWORK_SECMARK=y` (required by 7.3's `security/apparmor/lsm.c`,
  which calls `aa_secmark_enabled()` outside the `#ifdef` that defines it).
  Everything else (KVM/EL2/EFI/initrd) carried over unchanged — see
  `config-migration.md`.
- The built `Image` is a plain arm64 `Image` (no zImage/EFI-stub on arm64);
  the arm64 EFI boot path in NixOS uses the `Image` directly.

## 5. NixOS integration path

The flake exposes two outputs:

| Output | Type | Use |
|---|---|---|
| `packages.aarch64-linux.kernel` | the kernel **derivation** | what `nix build .#kernel` builds (Image/modules/dtbs) |
| `linuxPackages` (top-level) | the full `linuxPackagesFor (…) **attrset** | what a NixOS config assigns to `boot.kernelPackages` |

In a NixOS `configuration.nix` (with this repo as a flake input
`t14sKernel`):

```nix
boot.kernelPackages = t14sKernel.linuxPackages;
```

That attrset has exactly the shape `boot/kernel.nix` and
`boot/loader/systemd-boot.nix` consume: `config.boot.kernelPackages.kernel.{
name, features, config }`, the module packages, `ebpf-headers`, `systemd`,
etc. The plain `packages.…kernel` is kept separate so the flake's build gate
(`nix build .#kernel`) still means "just the kernel image".

Verified (by evaluation, no build): `t14sKernel.linuxPackages.kernel` is a
derivation named `linux-t14s-7.3.0` with `.dev`, `.modules`, `.config`,
`.features` sub-outputs.

## 6. EL2 / KVM status

`CONFIG_KVM=y`, `CONFIG_KVM_COMMON/MMIO/VFIO/GENERIC_HARDWARE_ENABLING/
GUEST_MEMFD=y` are all in the built config (carried from the 7.0.12 working
config, see `config-migration.md`), and the **EL2 device tree is built**:
`x1e78100-lenovo-thinkpad-t14s-oled-el2.dtb` is in the result. Whether that
DTB is what the firmware actually loads, and whether `/dev/kvm` then appears,
is the **Phase 8** boot test (`el2-verification.md`) — deferred, requires an
authorised reboot. The build itself is complete and correct.

## 7. Reproducibility / caveats

- `KBUILD_BUILD_TIMESTAMP=@$(SOURCE_DATE_EPOCH)` and
  `KBUILD_BUILD_VERSION=1-NixOS` are set by nixpkgs, so the Image is
  deterministic for a given (source, config, toolchain, nixpkgs pin).
- `flake.lock` is committed; bumping the pin changes the toolchain and thus
  the `RUSTC_VERSION` baked in — re-run the whole migration in that case
  (`maintenance-workflow.md` §2).
- The store also holds older, **failed** derivations
  (`b98fhlpdfp1sl459ii7x8z5gv13zadfc-…-dev`, the AppArmor-`secmark` failure
  before `CONFIG_NETWORK_SECMARK=y`). They are harmless; Nix GC will collect
  them. The **current** `dev`/`modules` are the `fvyjr3j1…`/`skap94a5…` pair.
