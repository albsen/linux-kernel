# EL2 Boot Model & Requirements (Phase 3)

> Technical investigation of how "EL2" is actually realised on this T14s,
> and what the Linux 7.3 kernel needs to boot with **working, usable EL2**.
> Reference baseline: `running-system-baseline.md` (Phase 1).

## 1. What "EL2" means here (the two models, resolved)

The brief asks us to distinguish:

- **Model A — "VHE":** the Linux kernel itself runs at EL2. KVM is in-kernel;
  no separate hypervisor is required to *be* the EL2 host. The kernel's own
  VHE hypervisor code (per-CU `el2_init`, `vhe_init`) runs at EL2 and provides
  the EL2 services; `/dev/kvm` is the KVM character device.
- **Model B — "EL1 + separate EL2 hypervisor":** Linux runs at EL1; a
  distinct EL2 hypervisor (e.g. a vendor/Qualcomm hypervisor or a PVM) is the
  EL2 owner, and Linux uses it as a *guest*.

### What the T14s / jglathe tree actually uses

The jglathe Qualcomm X1E (Snapdragon X Elite) tree implements **Model A —
Linux running at EL2 via VHE, with the Qualcomm Gunyah hypervisor as the
*underlying* hypervisor that hands EL2 to Linux** (not the reverse).
Evidence from the source:

- `arch/arm64/boot/dts/qcom/x1-el2.dtso` header comment:
  *"x1 specific modifications required to **boot in EL2**."*
- Same file, on the PCIe SMMU node: *"when **we take ownership of it in EL2**,
  we need to configure it properly to use PCIe"* and *"when running under
  Gunyah, this IOMMU is controlled by the firmware, however when we take
  ownership of it in EL2 …"* → i.e. **Linux (EL2) takes ownership** of the
  IOMMUs that Gunyah (the resident hypervisor) had been managing.
- Same file, on the SBSA watchdog: *"The 'SBSA watchdog' is implemented in
  software in Gunyah and can't be used when running in EL2"* → disabled for
  the EL2 case.
- `&scm { qcom,shm-bridge-vmid = <QCOM_SCM_VMID_SELF_OWNER>; }` — the Secure
  Channel Manager is configured with the **self-owner** VMID: Linux at EL2 is
  the "self owner" VM, not a nested guest.
- The base DTS (`x1e78100-lenovo-thinkpad-t14s.dtsi` family) is the normal
  EL1 device tree; the `-el2.dtb` is built by **applying the `x1-el2.dtbo`
  overlay** to that base DTB.

**Conclusion:** "EL2" on this machine = *Linux running at ARM64 EL2*
(the VHE model), where a Qualcomm Gunyah hypervisor sits underneath and has
transferred EL2 ownership to Linux. This is **not** "Linux at EL1 with a
separate EL2 hypervisor as the *outer* layer" — the outer hypervisor (Gunyah)
exists, but the *running Linux* is the EL2 owner.

> This resolves the ambiguity the baseline (Phase 1) raised. The running
> 7.0.12 generation is **nominated** to be Model A ("el2"), and the 7.3 tree's
> `-el2.dtb` device trees are exactly the Model A build.

## 2. Why the running 7.0.12 had `CONFIG_KVM=y` but **no** `/dev/kvm`

This is the single most important observation from the live system
(`running-system-baseline.md` §5):

- The running kernel is the **7.0.12 "el2" generation**, i.e. it was booted
  with the `x1e78100-lenovo-thinkpad-t14s-oled-el2.dtb` (EL2 overlay applied).
- Its running config has `CONFIG_KVM=y` (KVM built-in), yet **`/dev/kvm`
  does not exist** and no KVM/VHE symbols are present in the running config.

Interpretation, reconciling all evidence:

1. **`/dev/kvm` is created by KVM only when the kernel has determined VHE is
   available** (it registers the `arm-vhe` KVM machine). On this hardware the
   firmware *does* hand EL2 to Linux (that is the whole point of the EL2 DT),
   so a *correctly* initialised kernel would expose `/dev/kvm`.
2. The 7.0.12 tree's `x1-el2.dtso` was **incomplete** (see §4). Specifically the
   7.0.12 version was *missing* the `&soc { dma-ranges / ranges }` node and
   had the `remoteproc_*` IOMMU lines *active* rather than commented, and it
   **pre-dated** the split-out `x1-el2-pas.dtso`. So the 7.0.12 EL2 DT was
   functionally weaker; KVM's VHE init path plausibly did not complete, or the
   generation simply booted the *base* (non-EL2) DTB despite the "el2" label,
   so no `/dev/kvm`.
3. **No VHE symbol is expected** in either config: `CONFIG_ARM64_VHE does not
   exist as a Kconfig option in 7.0 or 7.3** — VHE is decided at runtime by the
   cpufeature machinery (the kernel detects `FEAT_VHE`/`AA64MMFR0.ECV` and
   calls the VHE init). So the *absence* of a VHE config symbol in the running
   config is **normal and expected**, not a missing feature. What *does* exist
   as a config symbol is `CONFIG_KVM` (and the arm64 hyp init is unconditional
   once KVM is in). `CONFIG_KVM=y` is present and correct.

So the 7.3 migration's job is **not** to add a new Kconfig VHE switch, but to
ensure the **EL2 device tree** (the `-el2.dtb`) is complete and the kernel is
built so that, when booted with it, KVM's VHE path initialises and `/dev/kvm`
appears.

## 3. What the 7.3 source already provides for EL2

The jglathe 7.3.0-jg-5 tree **already contains the complete EL2
infrastructure**, and it is *newer and more complete* than the 7.0.12
reference. No new EL2 patches are required. Concretely:

### 3.1 Device trees (all present in the 7.3 tree)

| File | Role |
|---|---|
| `x1e78100-lenovo-thinkpad-t14s.dts` / `.dtsi` | T14s **LCD** base DT |
| `x1e78100-lenovo-thinkpad-t14s-oled.dts` / `.dtsi` | T14s **OLED** base DT (matches running `compatible`) |
| `x1-el2.dtso` | **Base EL2 overlay** (SOC dma-ranges, PCIE SMMU ownership, GIC-ITS MSI, zap-shader disable, SCMI self-owner VMID) |
| `x1-el2-pas.dtso` | EL2 + PAS-managed remoteproc IOMMU variant (`#include "x1-el2.dtso"` + adsp/cdsp `iommus`) |
| `sc7180-el2.dtso`, `sc8280xp-el2.dtso`, `monaco-el2.dtso`, `talos-el2.dtso`, `lemans-el2.dtso` | EL2 overlays for other platforms (not relevant to T14s, but part of the same family) |

### 3.2 Makefile wiring (EL2 DTBs are a first-class build target)

From `arch/arm64/boot/dts/qcom/Makefile` (7.3):

```
436: dtb-$(CONFIG_ARCH_QCOM) += x1-el2.dtbo          # standalone overlay build
437: DTC_FLAGS_x1-el2 := -Wno-avoid_default_addr_size
445: x1e78100-lenovo-thinkpad-t14s-el2-dtbs    := x1e78100-lenovo-thinkpad-t14s.dtb x1-el2.dtbo
446: dtb-$(CONFIG_ARCH_QCOM) += ... x1e78100-lenovo-thinkpad-t14s-el2.dtb
447: x1e78100-lenovo-thinkpad-t14s-oled-el2-dtbs := x1e78100-lenovo-thinkpad-t14s-oled.dtb x1-el2.dtbo
448: dtb-$(CONFIG_ARCH_QCOM) += ... x1e78100-lenovo-thinkpad-t14s-oled-el2.dtb
```

So a plain `make dtbs` (or the Nix kernel build's DTB target) **already
produces** `x1e78100-lenovo-thinkpad-t14s-oled-el2.dtb` for the exact target
machine — no patching needed. This is the DTB the bootloader must select for
the EL2 boot.

### 3.3 Kernel Kconfig / hyp code

- `CONFIG_KVM=y` (in the 7.3 running-equivalent config and in
  `arch/arm64/configs/defconfig` / `ubuntu_x1e_defconfig`).
- The arm64 hyp init (`arch/arm64/kvm/hyp/vhe/init.c`, `arch/arm64/kernel/`)
  is present and **unconditional** on VHE at build time; at boot the kernel
  detects VHE support from firmware and runs the VHE init at EL2.
- No new `CONFIG_*_VHE` symbol needs to be added (it does not exist).

### 3.4 The 7.0.12 → 7.3 `x1-el2.dtso` diff (why 7.3 is better)

Diff of `x1-el2.dtso`, 7.0.12 steev → 7.3 t14s:

```
7.3 ADDED (not in 7.0.12):
  + &soc {
  +     #address-cells = <2>;
  +     #size-cells = <2>;
  +     dma-ranges = <0 0 0 0 0x100 0>;
  +     ranges = <0 0 0 0 0x100 0>;
  + };
  7.3 CHANGED:
  - &gpu_zap_shader { status = "okay";  firmware-name = "qcom/vpu/vpu30_p4.mbn"; }
  + &gpu_zap_shader { /* status/firmware commented out — use generic firmware in EL2 */ }
  7.3 CHANGED (remoteproc IOMMU moved to the dedicated PAS overlay):
  - &remoteproc_adsp { iommus = <&apps_smmu 0x1000 0x80>; }   (was active in base)
  - &remoteproc_cdsp { iommus = <&apps_smmu 0x0c00 0x0>; }     (was active in base)
  + (now in x1-el2-pas.dtso; in base x1-el2.dtso they carry
  +   `qcom,broken-reset;` and the iommus are commented out)
```

So 7.3 (a) fixes the SOC address/range mapping required for the apps-SMMU to
be correctly owned in EL2, (b) cleans up the VPU zap-shader handling, and (c)
splits the PAS-specific remoteproc IOMMUs into a dedicated overlay — exactly
the change the 7.0.12 patch series tried to make by hand. **The 7.0.12 patch
`0008-x1-el2-pas.dtso` is therefore already fully contained in the 7.3 source
as a first-class file.**

## 4. Is the 7.0.12 `x1-el2-pas.dtso` patch needed in 7.3?

**No.** The 7.0.12 patch `0008-arm64-dts-qcom-x1-Add-x1-el2-pas.dtso` adds the
file `x1-el2-pas.dtso` whose *entire* content (`#include "x1-el2.dtso"` +
adsp/cdsp `iommus`) is **byte-for-byte present** in the 7.3 tree at
`arch/arm64/boot/dts/qcom/x1-el2-pas.dtso`, and it is wired into the Makefile
for the relevant boards. Porting it would be a no-op (and would conflict).
→ **Do not port; it is upstream.**

## 5. Requirements for a bootable 7.3 kernel with usable EL2

For the new 7.3 kernel to boot NixOS with working EL2 on this T14s:

1. **Correct device tree selection at boot.** The bootloader (GRUB/UEFI
   entry, or NixOS `deviceTree` option) must select
   `x1e78100-lenovo-thinkpad-t14s-oled-el2.dtb` (OLED) — i.e. the base DTB +
   `x1-el2.dtbo` overlay — not the plain `...-t14s-oled.dtb`. This is a
   **boot-environment** concern handled at NixOS integration time (Phase 7/8),
   not a source change.
2. **Firmware must hand EL2 to Linux.** On Snapdragon X Elite this is the
   normal UEFI/Qualcomm-boot flow for the `-el2` DTBs; the kernel's VHE path
   then takes over. No firmware change is made by this project (constraint 10/13).
3. **`CONFIG_KVM=y`** (already in the migrated config) so the in-kernel KVM
   (VHE) host is built. With the EL2 DTB applied, `arm_vhe_hyp_init()` runs at
   EL2 and `/dev/kvm` is created.
4. **No new Kconfig VHE symbol** is required (none exists).

## 6. Verification of "working EL2" (deferred to Phase 8, authorised)

After the user-authorised deployment + reboot on the new kernel, the EL2
behaviour is confirmed by:

```bash
uname -r                                   # should report 7.3.0-jg-5 (EL2 build)
ls -l /dev/kvm                             # MUST exist (was absent on 7.0.12)
dmesg | grep -Ei 'kvm|hyp|VHE|EL2|vhe'    # "KVM: … VHE" / EL2 init lines
# optional functional probe:
kvm_stat 2>/dev/null | head; lsmod | grep -i kvm
```

**Passing criteria (Phase 8):** `/dev/kvm` present **and** a KVM VM can be
created/run (or at minimum the VHE init lines appear in dmesg without
hypervisor-init errors). A *missing* `/dev/kvm` on the new 7.3 EL2 kernel
would mean the migration failed to reproduce the EL2 handoff — that is the
primary failure signature to watch for, and it is what the 7.0.12 baseline
exhibited.

## 7. Differences from Linux 7.0.12 (EL2-relevant only)

| Item | 7.0.12 reference | 7.3 (this project) |
|---|---|---|
| `x1-el2.dtso` | base version (no `&soc` ranges; zap-shader active) | **updated** (`&soc` dma/ranges, zap-shader generic, remoteproc split) |
| `x1-el2-pas.dtso` | **absent** (added only by hand patch 0008) | **present as first-class file** |
| T14s OLED EL2 DTB | built via `…-t14s-oled-el2-dtbs` | same target, from a more complete overlay |
| KVM symbol | `CONFIG_KVM=y` (no VHE symbol; none exists) | `CONFIG_KVM=y` (unchanged model) |
| Runtime result (observed) | `CONFIG_KVM=y` **but no `/dev/kvm`** | **target: `/dev/kvm` present** (to be verified at Phase 8) |

## 8. Outstanding questions

- Whether the *running* 7.0.12 "el2" generation actually booted the EL2 DTB or
  the base DTB cannot be confirmed from the unprivileged shell (no dmesg). The
  **absence of `/dev/kvm`** is the concrete symptom; the 7.3 `-el2.dtb` +
  complete `x1-el2.dtso` is the fix, and Phase 8 confirms it.
- Whether `x1-el2-pas.dtso` (vs plain `x1-el2.dtso`) is the variant this
  specific board wants for its remoteproc/IOMMU setup is a per-firmware
  question; the default NixOS build uses the plain `x1-el2.dtbo` (matching
  what 7.0.12 applied to the OLED via the `…-el2.dtb`), and that is the
  conservative, already-demonstrated choice.
