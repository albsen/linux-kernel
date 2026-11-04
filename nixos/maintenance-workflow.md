# Rebase / Migration / Maintenance Workflow (Phase 9)

How to keep `t14s_linux_kernel` on jglathe's line, and how to re-migrate the
local configuration + Nix packaging when new upstream versions appear.
The one-off work already done (Phases 1–8) is the reference; this doc is the
**repeatable procedure**.

Repo layout recap:

```
t14s_linux_kernel/                 <- independent clone of jglathe kernel_7.3.x
├── .git/                          <- own repo; branch t14s-7.3.0-jg-5
│                                   <- origin = local jglathe kernel_7.3.x checkout
├── flake.nix / flake.lock         <- Nix build + devShell (nixos/ dir is in-repo)
└── nixos/
    ├── working_el2-7.3.config    <- the config the Nix build consumes
    ├── boot-el2.md  upstream.md  patch-reference.md
    ├── running-system-baseline.md  config-migration.md
    ├── el2-verification.md       <- Phase 8 procedure
    └── build.md                  <- Phase 7 build results (when the build lands)
```

The only *local* deltas on the branch are:
1. the `nixos/` docs + `working_el2-7.3.config`, and
2. `flake.nix` / `flake.lock`.

**No kernel source patches are applied** (Phase 4 concluded: 0 of the 13
7.0.12 patches need porting; the 7.3 tree already carries the EL2 DTS work).
If that ever changes, the new patch goes into `flake.nix` `kernelPatches`
(and must be reproducible — prefer git-format patches checked into `nixos/patches/`).

## 1. Routine update: new jglathe release (e.g. `7.3.0-jg-6`)

1. **Pull upstream** (on the host, where `jglathe_linux_kernel` lives is read-only
   for us; `origin` here is a local path to it, so this is just a fetch):
   ```sh
   cd t14s_linux_kernel
   git fetch origin                          # origin = ../jglathe_linux_kernel
   ```
2. **Create a new tracking branch** (do not fast-forward the old one):
   ```sh
   git switch -c t14s-7.3.0-jg-6 origin/<new-jglathe-branch-or-tag>
   ```
3. **Re-migrate the config** — see §2. The key step is re-running
   `olddefconfig` with the *new* tree's Kconfig and the same toolchain,
   because *new* Kconfig symbols get their defaults while old ones carry over.
4. **Re-validate** the same three gates (see §3).
5. **Commit** the new `working_el2-<ver>.config` + doc updates on the new branch;
   keep the branch name pattern `t14s-<version>-jg-<n>` so the generation is
   self-describing in the flake.

## 2. Config migration procedure (the repeatable core)

Always from the last *known-working* config, never from a stale in-tree one:

```sh
cd t14s_linux_kernel
# 0) stage last known-good config (here: previous version's file in nixos/)
cp nixos/working_el2-<oldver>.config .build/.config

# 1) let the NEW tree re-resolve it
nix develop .#default --command \
  bash -c 'make O=$PWD/.build ARCH=arm64 LLVM=1 olddefconfig && \
            make O=$PWD/.build ARCH=arm64 LLVM=1 rustavailable'

# 2) audit the diff the same way as Phase 5 (config-migration.md §"What changed")
#    — specifically:
#    - RUST / RUST_IS_AVAILABLE still =y  (else something in the devShell broke)
#    - KVM/EL2/EFI/initrd symbols unchanged
#    - any symbol that flipped to a *wrong* default gets a manual pin,
#      documented in config-migration.md as a deliberate change (see the
#      CONFIG_NETWORK_SECMARK=y precedent from this 7.3 migration)

# 3) promote
cp .build/.config nixos/working_el2-<newver>.config
```

Toolchain notes that make step 1 work:
- `olddefconfig` must run **inside `nix develop`** so `rustc` is on PATH —
  otherwise `CONFIG_RUST` silently drops to `#not set` (Phase 5 finding).
- The flake pins the nixpkgs used for the config migration and for the build
  identically, so the `RUSTC_VERSION` written into the config matches what the
  build later uses. If you bump the pin, re-run the whole migration
  (version bump → new `olddefconfig` → new config file).

## 3. Validation gates (run after any config or source change)

All three must pass, in order, before the kernel is considered buildable:

```sh
# G1: flake + devShell evaluate
nix flake check . --no-build

# G2: Kconfig is self-consistent AND rust is available (in the devShell)
nix develop .#default --command \
  bash -c 'make O=$PWD/.build ARCH=arm64 LLVM=1 olddefconfig && \
            make O=$PWD/.build ARCH=arm64 LLVM=1 rustavailable'
# expected: "Rust is available!"

# G3: full native build
nix build .#kernel -L --max-jobs 8        # (jobs: ~80% of nproc on the T14s,
                                           #  per user preference on battery)
# success = .#kernel result with:
#   <pkg>/Image, <pkg>/dtbs/.../x1e78100-lenovo-thinkpad-t14s-oled-el2.dtb,
#   <pkg>-modules/lib/modules/<modDirVersion>/
```

## 4. NixOS integration maintenance

The host-side integration is a **one-liner in the NixOS config** (no flake
machinery beyond `inputs` on the NixOS side):

```nix
# configuration.nix
{
  imports = [ ];
  boot.kernelPackages = t14sKernel.linuxPackages;
  # where, in the host flake:
  #   inputs.t14s.url = "path:/path/to/t14s_linux_kernel";
  # `.linuxPackages` is the top-level output of this flake: the full
  # `pkgs.linuxPackagesFor (linuxManualConfig …)` attrset.
}
```

When rebasing (§1), this line does **not** change — only the branch/commit the
path points at does. Rebuild the NixOS generation, and the bootloader keeps
the previous generation as fallback (`el2-verification.md` §4).

## 5. When upstream starts carrying what we used to pin manually

The Phase-4 audit showed 7.3 already contains the 7.0.12-era EL2 work. Keep
watching jglathe's merge activity for:
- new `x1-el2*.dtso` variants (e.g. for other T14s panel types — the `-oled`
  one is the one this machine uses; a future `…-t14s.dtb` non-oled would need
  its own `linuxManualConfig` if you support both),
- changes under `arch/arm64/boot/dts/qcom/x1*` and `drivers/firmware/qcom/`
  (the SCM/Gunyah path),
- KVM/arm64 VHE changes.

If any of those land such that a *new* local patch or a *new* config pin is
required, follow §2 (pin the config) and/or add the patch to
`flake.nix:kernelPatches` + `nixos/patches/`, and note it in
`patch-reference.md` (which is the standing register of "why is/aren't we
carrying patch N").

## 6. Housekeeping

- **Never** push this branch to a remote (local-only by design); if a remote
  becomes needed, confirm with the user first.
- **Never** modify `kernel_7.0.12/` (reference) or `jglathe_linux_kernel`
  (upstream source) — see the project constraints in `upstream.md`.
- The `.build/` out-of-tree dir is disposable; it is git-ignored and can be
  `rm -rf`'d at any time (a fresh `olddefconfig` rebuilds its host tools).
- Keep `flake.lock` committed; the pin is what makes the config's
  `RUSTC_VERSION` reproducible.
