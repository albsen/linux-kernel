# Upstream Provenance (Phase 2)

## Repository

- **Path:** `kernel_7.3.x/t14s_linux_kernel/`
- **Upstream source:** `kernel_7.3.x/jglathe_linux_kernel/` (jglathe's
  Qualcomm `ubuntu-qcom-x1e` Linux 7.3 tree; untouched by this project).
- **Relationship:** `t14s_linux_kernel` is an **independent local clone** of
  the jglathe tree, with its own `.git/` object store. `origin` points at the
  local jglathe path (used only for future refetch); **no remote pushes occur**.

## Base revision

| Field | Value |
|---|---|
| Upstream ref (tag) | `jg/ubuntu-qcom-x1e-7.3.0-jg-5` |
| Upstream ref (branch) | `jg/ubuntu-qcom-x1e-7.3.0-jg-5` |
| Base commit (full SHA) | `0546ca4ebda4136c27c515ee1721f52a19adc80a` |
| Commit subject | `Ubuntu: Update changelog to 7.3.0-jg-5` |
| Kernel version (Makefile) | `VERSION=7 PATCHLEVEL=3 SUBLEVEL=0` |
| Local development branch | `t14s-7.3.0-jg-5` |
| Local HEAD SHA | `0546ca4ebda4136c27c515ee1721f52a19adc80a` (identical to base) |
| History depth | **1,486,228 commits** (full upstream history preserved) |
| Tracked files | 96,370 |

## Verification performed

1. `git rev-parse HEAD` in `t14s_linux_kernel`
   `== git rev-parse 0546ca4ebda4…` in `jglathe_linux_kernel` → **MATCH**.
2. `git log --oneline <base>..HEAD` → **empty** (no local commits have been
   made yet; the branch is a pure base checkout).
3. `git status -s` → only `?? nixos/` (this project's documentation +
   config). No tracked-file modifications, no staged changes.
4. `.git` is a real directory (independent object store), not a `gitfile`.
5. `git describe --tags` → `jg/ubuntu-qcom-x1e-7.3.0-jg-5` (the tag sits
   exactly on HEAD).

## What is intentionally **not** in this repo

- **No Ubuntu packaging.** The tree still contains `debian/`, `Ubuntu.md`,
  and Ubuntu changelog commits (they are part of the upstream history and are
  preserved — we do *not* rewrite history or delete files for cosmetic
  reasons). They are simply **not used** by the Nix build (see Phase 6): the
  kernel is built through NixOS's `linuxManualConfig` against the raw tree,
  so Debian/Ubuntu packaging has no effect on the build.
- **No ported 7.0.12 patches yet.** The 7.0.12 `lenovo-t14s-linux-7.0.y`
  series (13 patches) is a *reference* only; see `patch-reference.md`
  (Phase 4) for the decision on each.

## Why a local clone (not a fetch)

The brief requires the repository to "descend directly from the selected
jglathe commit" and to contain "the complete kernel source, not only a flake
referencing another repository." A full local clone satisfies both: the
result is a self-contained, buildable, full-history Git repo. Nix fetches
from *this* tree (via the flake's `src`), not from an external GitHub URL.
