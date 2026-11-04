# Patch Reference Review (Phase 4)

Lightweight review of the 13-patch `lenovo-t14s-linux-7.0.y` series
(`kernel_7.0.12/kernel-patches/lenovo-t14s-linux-7.0.y/series.nix`). Per the
brief: **start with zero additional patches**, and port *only* what is
demonstrated necessary for boot or EL2. These are all jglathe commits (SHAs
`d0f38cd0…` … `2adac779…`) that were cherry-picked onto the 7.0.12 tree.

**Finding up front:** none of the 13 SHAs exist as commits in the 7.3 jglathe
tree (jglathe rebased/reworked the series between 7.0 and 7.3), so the test
is *content*, not SHA. The only EL2/boot-critical patch, **0008**, is already
fully present upstream in 7.3 (see `boot-el2.md` §4). Everything else is
display / audio / thermal / panel / USB-Phy feature work — none of it gates
EL2, and most targets *other* boards than the T14s.

## Per-patch verdict

| # | Patch (series name) | Area | T14s-relevant? | Present in 7.3 source? | Verdict |
|---|---|---|---|---|---|
| 0002 | `jg-…-dp-audio-inactive` — drm/msm/dp audio | display/audio | no (DP-audio on a laptop with no DP-out wired the same) | reworked upstream | **Skip** (not EL2; not boot-critical) |
| 0005 | `jg-…-sc8280xp-blackrock-usb-phy-supply` — sc8280xp DTS | USB (SC8280XP dev kit) | **no** (wrong SoC, not x1e) | n/a | **Skip** (wrong board) |
| 0008 | `jg-…-x1-el2-pas` — **Add `x1-el2-pas.dtso`** | **EL2 / remoteproc IOMMU** | **yes — the EL2 patch** | **YES — `x1-el2-pas.dtso` present, byte-identical, wired in Makefile** | **Upstream. Do NOT port.** |
| 0014 | `jg-…-lpass-wsa-pm-clock` — ASoC lpass-wsa-macro PM clock | audio | maybe (audio) | reworked upstream | **Skip** (audio, not EL2) |
| 0015 | `jg-…-lpass-va-pm-clock` — ASoC lpass-va-macro PM clock | audio | maybe (audio) | reworked upstream | **Skip** (audio, not EL2) |
| 0016 | `jg-…-sc8280xp-dispcc-mdp` — clk dispcc-sc8280xp | display (SC8280XP) | **no** (wrong SoC) | n/a | **Skip** (wrong board) |
| 0017 | `jg-…-surface-pro-12-panel` — drm/panel-edp surface-pro-12 | panel (Surface) | **no** (wrong machine) | n/a | **Skip** (wrong board) |
| 0019 | `jg-…-thinkbook-16-dp-dais` — x1p42100 thinkbook-16 DTS | display (ThinkBook 16) | **no** (ThinkBook, not T14s) | n/a | **Skip** (wrong board) |
| 0020 | `jg-…-thinkbook-16-gpi-dma` — x1p42100 thinkbook-16 DTS | display (ThinkBook 16) | **no** (ThinkBook, not T14s) | n/a | **Skip** (wrong board) |
| 0021 | `jg-…-panel-n140jce-el1` — drm/panel-edp N140JCE | panel | maybe (a specific EDP panel) | `N140JCE`/`0x1476` found in 7.3 `panel-edp.c` | **Upstream (reworked). Skip.** |
| 0023 | `jg-…-pmic5-gen3-adc-thermal` — thermal PMIC5 Gen3 ADC | thermal | maybe (thermal on x1e) | `qcom-spmi-adc-tm5-gen3.c` present in 7.3 | **Upstream (reworked). Skip.** |
| 0024 | `jg-…-pmic5-gen3-adc` — iio/adc QCOM PMIC5 Gen3 ADC | thermal/ADC | maybe (thermal on x1e) | `qcom-spmi-adc5-gen3.c` present in 7.3 | **Upstream (reworked). Skip.** |
| 0025 | `jg-…-pmic5-gen3-adc-bindings` — dt-bindings iio adc PMIC5 Gen3 | bindings | maybe | bindings present in 7.3 | **Upstream (reworked). Skip.** |

## EL2/boot-critical gap analysis

- **EL2:** only patch 0008 touches EL2. It is **already upstream** in 7.3 as
  the first-class file `x1-el2-pas.dtso` (and the base `x1-el2.dtso` is
  *more complete* in 7.3 than in 7.0.12 — see `boot-el2.md` §3.4). **No
  EL2 gap. Nothing to port.**
- **Boot (NixOS-specific):** none of the 13 patches are NixOS/bootloader/
  initrd-related; they are all Qualcomm hardware-enablement patches. The NixOS
  boot path (UEFI + initrd + Btrfs/NVMe root) is provided by the NixOS system
  config, not by any kernel patch. **No boot gap from these patches.**
- The only T14s-*relevant* (but non-EL2) items — the PMIC5 Gen3 ADC/thermal
  (0023/0024/0025) and the EDP panels (0017/0021) — already exist in the 7.3
  source in reworked form, so even if the user later wants better thermal
  readings or a specific panel, **the 7.3 tree already carries the equivalent
  functionality.** No action needed for the EL2 objective.

## Decision

**Zero patches are ported.** The 7.3 jglathe tree is used as-is, with:

- the migrated NixOS configuration (`nixos/working_el2-7.3.config`, Phase 5), and
- the Nix flake build wrapper (`flake.nix`, Phase 6).

This matches the brief: *"Start with zero additional patches. Add only changes
demonstrated to be necessary for boot or EL2."* The EL2 functionality is
entirely supplied by the already-present `x1-el2*.dtso` device-tree family and
the standard `CONFIG_KVM=y` arm64 VHE path — no patch is required to obtain
working EL2, and none is added.
