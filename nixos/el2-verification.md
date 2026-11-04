# EL2 Boot Verification & Deployment (Phase 8)

> **Deferred — do NOT auto-run.** This document defines *what to do* after
> the Phase 6/7 build succeeds, and *how to verify* that the new 7.3 kernel
> actually runs at EL2 (VHE) with a working `/dev/kvm` on the ThinkPad T14s.
> Nothing in this document has been executed yet. Rebooting requires explicit
> user authorisation (see `running-system-baseline.md` constraints).

Related: `boot-el2.md` (EL2 model), `config-migration.md`, `build.md` (build),
`upstream.md` (repo), `maintenance-workflow.md` (Phase 9).

## 0. What "EL2 works" means here

From `boot-el2.md`: the model is **Linux at EL2 (VHE) with Qualcomm Gunyah as
the underlying hypervisor**, signalled by the `x1-el2.dtso` /
`x1e78100-lenovo-thinkpad-t14s-oled-el2.dtb` device tree (SCM
`QCOM_SCM_VMID_SELF_OWNER`). The observable, user-space-visible consequence of
a *working* EL2/VHE kernel is:

1. the kernel comes up (reaches the initramfs → root fs), and
2. **`/dev/kvm` exists** and KVM reports VHE capability.

The current 7.0.12 generation is the reference state: it has
`CONFIG_KVM=y` + `id_aa64mmfr0.ecv=1` in its cmdline but **no `/dev/kvm`**
(`running-system-baseline.md` §5/§7). So the Phase-8 test doubles as the
resolution of the "EL2 unconfirmed" question from Phase 1.

**Success bar for this phase:** after booting the 7.3 kernel,
`test -e /dev/kvm` is true, and (optionally) a trivial KVM guest boots.

## 1. What the build produces (Phase 6/7 inputs)

From `nix build .#kernel` (`packages.aarch64-linux.kernel`
= `pkgs.linuxPackagesFor (pkgs.linuxManualConfig …)`):

| Output | Path (store) | Contents |
|---|---|---|
| kernel image | `<pkg>/Image` | arm64 `Image` (ELF, no zImage — arm64 `Image` target) |
| DTBs | `<pkg>/dtbs/…` | incl. **`x1e78100-lenovo-thinkpad-t14s-oled-el2.dtb`** (the EL2 one) |
| modules | `<pkg>-modules/lib/modules/7.3.0/` | built-in-free modules |
| System.map, config | `<pkg>/…` | via `dev`/`out` outputs |

`<pkg>` = `…-linux-t14s-7.3.0` (the `nix build .#kernel` result).

## 2. Deployment options (no auto-reboot)

### 2a. Full NixOS integration (the intended path)

Point a NixOS generation's `boot.kernelPackages` at **this** kernel
attrset. In a NixOS `configuration.nix` (on the host, with this repo's
`flake.nix` as a flake input `t14sKernel`):

```nix
{
  imports = [ ];

  boot.kernelPackages = (
    (import (t14sKernel.source + "/flake.nix") {
      inputs.nixpkgs = { url = "github:NixOS/nixpkgs/master"; };
    })
  ).packages.${system}.kernel;   # linuxPackagesFor attrset: { kernel, modules, dev, … }
  # equivalently: the attrset from `packages.<sys>.kernel` of the flake
}
```

Then, on the **host** (not this sandbox):

```sh
sudo nixos-rebuild switch          # or `build-vm` first; reboot only if you choose to
```

This reuses the running system's existing bootloader (GRUB on the ESP,
per `running-system-baseline.md` §4), the same `/kernels/…-Image`
convention, and the same initrd mechanism. **The bootloader is NOT
modified** by us.

### 2b. Manual GRUB entry (quicker, lower-risk test boot)

On the host, add a one-off GRUB entry (or a `customEntries`) that boots
`/kernels/<newstore>/linux-t14s-7.3.0-Image` with the **same cmdline as the
current `el2` generation** (reproduced in `running-system-baseline.md` §3),
i.e. keeping `id_aa64mmfr0.ecv=1`, `efi=noruntime`, `root=fstab`,
`init=<new-gen-init>`, etc. The `el2` DTB in the new package is selected by
the DTS overlay chain already baked into the `…-oled-el2.dtb`; the Image
itself is arch-generic.

> Which DTB the firmware picks at EL2 vs EL1 boot is firmware-policy
> dependent. The jglathe 7.3 tree *already* ships both the EL2 overlay
> (`x1-el2.dtso`) and the base board DTS (`…-oled.dts`), and the
> `…-oled-el2.dtb` is what the current working 7.0.12 generation's
> `…-el2` label corresponds to. If the machine boots the *base* (non-EL2)
> DTB by firmware policy, `/dev/kvm` will simply be absent — that is a
> firmware/bootloader-selection issue, not a build defect, and should be
> reported as such.

### 2c. What is deliberately NOT done

- No changes to the bootloader configuration, ESP, or EFI variables by the
  build or by this phase.
- No automatic `reboot`. Rebooting is a user action, after the new generation
  is in place and the user has confirmed the machine is safely suspended.

## 3. Verification procedure (run after an *authorised* reboot into 7.3)

Numbered; run in this order. Each step's pass/fail is recorded in the
verification report (template in §5).

```sh
# 1. We are actually on the new kernel
uname -r                                   # expect 7.3.0-NixOS (or 7.3.0-x)
uname -m                                    # aarch64

# 2. EL2/VHE: /dev/kvm now present?
test -e /dev/kvm && echo "KVM node PRESENT" || echo "KVM node ABSENT"
ls -l /dev/kvm

# 3. KVM reports what flavour (VHE vs nvhe)
cat /sys/module/kvm/parameters/vhe         # if present
dmesg | grep -iE 'kvm|vhe|hypervisor|gunyah' | head -40   # needs root/dmesg access

# 4. KVM API basic probe (userspace, no guest needed)
#    libkvm/libvirt-free minimal check: open /dev/kvm, KVM_GET_API_VERSION
python3 - <<'PY'
import ctypes, os
KVM = "/dev/kvm"
try:
    fd = os.open(KVM, os.O_RDWR)
except OSError as e:
    print("cannot open", KVM, e); raise SystemExit(1)
libc = ctypes.CDLL(None)
KVM_GET_API_VERSION = 0xae00
buf = ctypes.c_uint32(0)
r = libc.ioctl(fd, KVM_GET_API_VERSION, ctypes.byref(buf))
print("KVM api version:", buf.value, "(expect 12)")
os.close(fd)
PY

# 5. (Optional, only if 4 passed) smallest possible guest smoke test
#    requires a KVM guest tool (qemu-system-arm64) to be present on the host:
#    - a tiny -M virt -append "console=hvc0" image, or
#    - an existing known-good ARM64 guest image from the 7.0.12 era if one
#      exists on the box.
```

### Pass criteria (all must hold for "EL2 confirmed")

- `uname -r` = new 7.3 kernel.
- `/dev/kvm` exists.
- `KVM_GET_API_VERSION` ioctl returns **12**.
- (stronger) a minimal KVM guest boots to a shell.

### If `/dev/kvm` is still absent on 7.3

That is now a **diagnostic result, not a build failure**: it means the
firmware/boot chain handed the kernel a non-EL2 DTB (the base
`…-oled.dtb`) rather than the `-el2` variant, *or* the Gunyah/hypervisor state
this firmware revision expects was not met. The follow-up is to capture:
`/proc/device-tree/compatible`, the exact `.dtb` the firmware loaded (visible
in the bootloader log / `dmesg`), and compare against the 7.0.12 reference —
then report to the user with that evidence. The build itself is still valid
and the kernel is bootable; only the EL2 handoff is in question.

## 4. Rollback

- The previous generation (7.0.12 `…-oled-el2-…`) remains in the store and in
  the bootloader's generation list; selecting it at boot (or
  `sudo nixos-rebuild switch --system-path <old>`) restores it. **No manual
  bootloader surgery is needed** — NixOS keeps old generations bootable.

## 5. Verification report template

```
Date:            <YYYY-MM-DD>
Kernel:          <uname -r>
/dev/kvm:        present / absent
KVM API version: <n or n/a>
dmesg EL2 lines: <excerpt>
Guest test:      pass / not attempted / fail
Verdict:        EL2 confirmed / EL2 not confirmed (reason: …)
Rollback needed: yes/no
```

---

**Status:** pending Phase 6/7 build completion and explicit user authorisation
to reboot. Not executed.
