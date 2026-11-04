# Running-System Baseline (Phase 1)

> Reference point for the Linux 7.3 migration. Everything here is observed
> directly on the target machine (the coding agent is running on the actual
> ThinkPad T14s). Where a value could not be read from the current
> unprivileged shell, it is marked **not verifiable** — it is not guessed.

Collected: 2026-11-04.

## 1. Actual running kernel

| Property | Value |
|---|---|
| `uname -r` | `7.0.12` |
| `uname -m` | `aarch64` |
| Hostname | `rhea01` |
| Build line | `Linux 7.0.12 (nixbld@localhost) (gcc (GCC) 15.2.0, GNU ld (GNU Binutils) 2.46) #1-NixOS SMP PREEMPT` |
| Kernel Image (store) | `/nix/store/ik6cs6xyvjzcif6f26qha7wp3wd108hf-linux-7.0.12/Image` |
| Initrd (store) | `/nix/store/zwpyifbmk8hky5df242xd834qw9d33wx-initrd-linux-7.0.12/initrd` |
| DTB (store) | `/nix/store/ik6cs6xyvjzcif6f26qha7wp3wd108hf-linux-7.0.12/dtbs` |

Confirmed: the running kernel is the known-working **Linux 7.0.12**. No
discrepancy with the brief's statement.

## 2. NixOS generation

- Current system:
  `/nix/store/h7h91cbjgkcfq020qjq57i69d715cgms-nixos-system-rhea01-oled-el2-26.11.20260925.e94cb15`
- `configuration-name`: **`NixOS OLED EL2`**
- Boot label (from `boot.json`):
  `NixOS Zokor oled-el2-26.11.20260925.e94cb15 (Linux 7.0.12)`
- The current generation is explicitly the **"el2"** variant.

  > **Observation:** the store holds two parallel families of generations,
  > `...oled-el1...` and `...oled-el2...` (411 of each in `/nix/store`).
  > Only the **el2** generation is the current/running one. The "el1" family
  > are historical variants, kept as fallback. **Do not touch either family.**
- `/run/current-system` does **not** exist in this container (the agent runs
  inside a sandbox, not directly on the host root). The running generation is
  therefore identified via the store path resolved from the running kernel's
  store name and `boot.json`.

## 3. Boot parameters

Kernel command line (from `/proc/cmdline`, matches `boot.json`
`kernelParams`):

```
BOOT_IMAGE=(hd0,gpt1)//kernels/ik6cs6xyvjzcif6f26qha7wp3wd108hf-linux-7.0.12-Image
  init=/nix/store/h7h91cbjgkcfq020qjq57i69d715cgms-nixos-system-rhea01-oled-el2-26.11.20260925.e94cb15/init
  clk_ignore_unused
  pd_ignore_unused
  root=fstab
  cma=128M
  efi=noruntime
  id_aa64mmfr0.ecv=1
  iommu.strict=1
  mitigations=off
  crashkernel=2G-4G:320M,4G-32G:512M,32G-64G:1024M,64G-128G:2048M,128G-:4096M
  module_blacklist=algif_aead,esp4,esp6,rxrpc
  lsm=landlock,yama,bpf
  console=tty0
```

Notable for EL2/boot:

- `id_aa64mmfr0.ecv=1` — explicitly advertises ECV (Enhanced Virtualization
  Controls) at FEAT_AA64MMFR0, i.e. the kernel assumes VHE-capable EL2
  behaviour. This is a strong hint the firmware hands the kernel an
  EL2/VHE-capable state.
- `mitigations=off` — security mitigations disabled (expected on this
  platform for performance; keep as-is).
- No explicit `kvm=` or `hv_` / hypervisor command-line option is present.
  EL2 enablement is therefore expected to come from the **device tree /
  firmware handoff**, not from the kernel command line.

## 4. Boot environment (EFI / bootloader)

- Bootloader boots the kernel from `/(hd0,gpt1)/kernels/...-linux-7.0.12-Image`
  — i.e. a **UEFI/GRUB** path on the EFI System Partition (`/boot`, a `vfat`
  partition: `/dev/nvme0n1p1`).
- `efi=noruntime` in the command line: the UEFI runtime services are disabled
  once the kernel is up (standard for NixOS).
- The kernel is loaded directly as `...-Image` (the NixOS arm64 `Image`
  ELF), consistent with an arm64 UEFI boot chain.
- **Root fs:** `/dev/mapper/cryptroot` (LUKS) → Btrfs, subvol `@`,
  mounted `ro,compress=zstd:3`. 1.9 T, 39 % used.
- **Not verifiable from this unprivileged shell:** `/boot`, `/boot/efi`,
  `/var/log` and `/nix/var/nix/gcroots are all permission-denied. EFI
  environment variables, GRUB config, and any firmware settings that control
  EL2 handoff could not be read directly. They are left to the Phase 3 EL2
  investigation (source comparison) and the Phase 8 deployment test.

## 5. Current KVM / EL2 status

Observed from the running kernel's **effective** configuration
(`/proc/config.gz`, 12596 lines) and device nodes:

| Signal | Value |
|---|---|
| `CONFIG_KVM` | `=y` (built into the kernel, not a module) |
| `CONFIG_KVM_COMMON` / `MMIO` / `VFIO` / `GENERIC_HARDWARE_ENABLING` / `GUEST_MEMFD` | all `=y` |
| `CONFIG_SYS_HYPERVISOR` | `=y` |
| `# CONFIG_NVHE_EL2_DEBUG` | not set |
| **Any `CONFIG_ARM64_VHE` / VHE / NVHE symbol** | **absent** from the running config |
| `/dev/kvm` | **does not exist** |
| `lsmod | grep kvm` | empty (consistent with KVM being built-in, not a module) |
| `dmesg` / `/dev/kmsg` | **not readable** from this unprivileged shell |

### Interpretation (the crux of this project)

1. **KVM is compiled in** (`CONFIG_KVM=y`) but **`/dev/kvm` is absent** in the
   running system. That means the KVM arm64 host **did not successfully
   initialise** at boot in this generation, *or* it is gated behind a runtime
   condition this shell cannot observe (dmesg is unreadable).
2. The running config contains **no VHE / non-VHE symbol at all**, yet
   `id_aa64mmfr0.ecv=1` is on the command line and the generation is *named*
   "el2". On a VHE system `CONFIG_ARM64_VHE` (or the corresponding
   errata/feature set) would normally be present. Its absence here is
   significant: the "el2" label most likely refers to the **Qualcomm X1E
   firmware/hypervisor handoff** (the `x1-el2-pas` device-tree path, see
   §7 and `boot-el2.md`), **not** to a Linux-native VHE kernel running the
   whole kernel at EL2.
3. **This must be resolved, not assumed.** The two execution models are
   different and the brief explicitly requires us to report which one is real:
   - **Model A — "VHE":** the whole Linux kernel runs at EL2 (KVM in-kernel,
     no separate hypervisor). Evidence would be VHE config symbols + a
     working `/dev/kvm`.
   - **Model B — "EL1 + EL2 hypervisor (non-VHE / passthrough)":** Linux runs
     at EL1; a Qualcomm-provided EL2 hypervisor/firmware (the "PAS"/EL2
     passthrough enabled via device tree) provides the EL2 services that the
     `id_aa64mmfr0.ecv=1` / KVM path then uses. The missing `/dev/kvm` is
     consistent with KVM never binding because the required EL2 device-tree
     node (`x1-el2-pas.dtso`) is not yet present in this 7.0.12 build, *or*
     with KVM being compiled but its host init failing on this silicon.

   **From the unprivileged shell I cannot distinguish A from B with certainty**
   (no dmesg, no root). The baseline is recorded honestly as **"EL2 status
   unconfirmed; KVM built-in but /dev/kvm absent; VHE config symbols absent;
   `id_aa64mmfr0.ecv=1` present"**, and the distinguishing evidence is deferred
   to Phase 3 (source) + Phase 8 (authorized boot test).

## 6. Relevant configuration symbols (7.0.12 running config)

EL2 / KVM / virtualisation (the ones that matter):

```
CONFIG_KVM=y
CONFIG_KVM_COMMON=y
CONFIG_KVM_MMIO=y
CONFIG_KVM_VFIO=y
CONFIG_KVM_GENERIC_DIRTYLOG_READ_PROTECT=y
CONFIG_KVM_GENERIC_HARDWARE_ENABLING=y
CONFIG_KVM_GUEST_MEMFD=y
# CONFIG_NVHE_EL2_DEBUG is not set
CONFIG_SYS_HYPERVISOR=y
CONFIG_KERNEL_MODE_NEON=y
CONFIG_ARM64_AMU_EXTN=y
CONFIG_ARM64_EPAN=y
CONFIG_ARM64_ERRATUM_1418040=y
CONFIG_ARM64_ERRATUM_2645198=y
CONFIG_ARM64_ERRATUM_1463225=y
```

Boot / EFI / initrd (required to preserve):

```
CONFIG_BLK_DEV_INITRD=y
CONFIG_EFI=y
CONFIG_EFI_ARMSTUB=y
CONFIG_EFI_STUB=y
CONFIG_EFI_VARS=y
CONFIG_INITRAMFS_SOURCE=""
CONFIG_BTRFS_FS=y
CONFIG_SQUASHFS (initrd) ...
```

Full 7.0.12 reference: `kernel_7.0.12/kernel-configs/working_el2.config`
(12598 lines).

## 7. Virtualisation / EL2 test result

- **No live KVM test performed.** `/dev/kvm` does not exist, so a
  `/dev/kvm`-based capability/VM-creation test is impossible in the current
  state; attempting one would only confirm "no /dev/kvm".
- **No reboot / firmware/bootloader modification performed** (per constraints).
- **Open question carried to Phase 3:** whether the `x1-el2-pas.dtso`
  device-tree overlay (present in the 7.0.12 patch series as
  `0008-arm64-dts-qcom-x1-Add-x1-el2-pas.dtso-for-PAS-manage`) is what
  actually makes the Qualcomm EL2/passthrough path active, and whether that
  node is already present in jglathe's 7.3 source.

## 8. Current limitations / unresolved questions

1. **EL2 vs EL1 is not directly confirmable** from this unprivileged shell
   (no dmesg, no root, `/dev/kvm` absent, no VHE config symbols). The
   "el2" generation label + `id_aa64mmfr0.ecv=1` + `CONFIG_KVM=y` vs. the
   **missing `/dev/kvm`** and **missing VHE symbols** is the central
   inconsistency to resolve. → resolved in `boot-el2.md` (Phase 3) and
   finally by the Phase 8 boot test.
2. **`/boot`, EFI env, GRUB, `/var/log`, gcroots** are not readable from
   this shell; the EFI/GRUB side of the boot chain is documented only from
   `boot.json` + `/proc/cmdline`.
3. **The 7.0.12 `x1-el2-pas.dtso` patch** is the prime EL2-related artifact;
   its 7.3 equivalent is investigated in Phase 3/4.
4. The 7.0.12 config and source are the **reference**; the jglathe 7.3 tree is
   the **implementation base**. Neither is modified by this phase.

---

**Bottom line for the migration:** the target is a *bootable* NixOS Linux
7.3 kernel that reproduces (or improves on) the current "el2" behaviour —
i.e. a kernel that, once booted on this T14s, exposes a **working, usable
EL2** (confirmable by the presence of `/dev/kvm` and, ideally, a small KVM
VM test). The current 7.0.12 state is the behavioural reference even though
its `/dev/kvm` is currently absent — that absence is part of what the 7.3
kernel is expected to fix or explain.
