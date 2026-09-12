# Handoff: disk sizing, install profiles, and what still needs verifying

Written 2026-09-12 for whoever picks up born2root from `~/goinfre/born2root`.
Everything below was measured or read from the tree at commit `6f019e6`
(`origin/main`); nothing is assumed. Sections marked **OPEN** are the work
that remains.

## Ground rules that were learned the hard way

- **Never touch the VM in `/sgoinfre/students/dlesieur/born2root`.** It is
  the owner's working machine (120 GB virtual, 43 GB real, LUKS with no
  discard). It is stopped and must stay as it is unless the owner says so.
- **"Is the VM running?" means `fuser <qcow2>`**, never
  `pgrep -x qemu-system-x86_64` — the kernel truncates process names to 15
  characters and the full-name match returns nothing while QEMU is live. A 43
  GB copy was once taken from a running image because of this.
- **Run `git status` before editing.** `make all` / `make pull` do
  `git pull --autostash`; a conflicting re-apply leaves `<<<<<<<` markers with
  no error at the point of use, and `bash -n` passes them. Grep for them.
- **Commit before any `make all`** for the same reason: the pull stashes
  uncommitted work, and while a build is running do not edit files it reads.
- **Every script runs under `hellish`** (`SHELL := $(SCRIPT_SH)`). Validate
  with `hellish -n` as well as `bash -n`, and run path/list logic under
  hellish before calling it fixed. Known differences: `$(cd … && pwd -P)`
  returns the logical path; `$'\n'` is not expanded inside `${v:+…}`; a
  one-line `case … esac; }` becomes `esac }` under shfmt and hellish cannot
  parse that (write such functions multi-line).
- **`/goinfre` is per-machine and wiped.** On 2026-09-12 it was: the tree
  came back as a fresh clone (8.7 MB), the ISOs, the built VM, the nested
  repos and `~/goinfre/Inception` were gone. Only pushed commits survive.

## State on 2026-09-12

| Thing | State |
|---|---|
| `~/goinfre/born2root` | fresh clone of `origin/main` at `6f019e6`, clean |
| ISOs, `disk_images/b2r` | gone (wiped) — nothing built yet on this tree |
| `/sgoinfre/students/dlesieur/born2root` | same commit, plus untracked `42ctl/ evals42/ vault42/`; 46 GB, old VM inside, stopped, untouched |
| `~/goinfre/Inception` | gone; the nginx Dockerfile fix below was uncommitted and is **lost** |
| Docker data-root (`/goinfre/dlesieur/docker`) | empty |
| CI (`.github/workflows/ci.yml`) | shellcheck, bashate, shfmt, markdownlint, `make --dry-run all`, `make gen_iso` — all green locally at `6f019e6` |

## What was done, in order

1. `173d703` — **Root cause of the 45 GB footprint, fixed at the source.**
   The 42.7 GB qcow2 was not a big guest; it was (a) a 120 GB default disk,
   (b) a decoy `spare` LV formatted then deleted, and (c) a LUKS guest with
   **no discard anywhere** (no `discard` in crypttab, no `issue_discards`, no
   `fstrim.timer`), so `discard=unmap` on the QEMU drive never received a
   TRIM and freed blocks were ciphertext that `qemu-img convert` could not
   drop. `preseeds/b2b-setup.sh` now wires crypttab + `update-initramfs`,
   lvm.conf, `fstrim.timer`, swap `discard`, `tune2fs -m 1`; first boot runs
   `fstrim -av` once. Also: `LUKS=ON|OFF` build switch (ON = default and the
   only submittable mode; OFF writes `*-nocrypt.iso` so the modes cannot be
   cached into each other), `make space` (budget, exits 1), `make slim`
   (drop ISOs, apt-clean, fstrim, optional `qemu-img convert`), and the
   shfmt-collapsed `esac }` that broke `make qemu_start` under hellish.
2. `bb168dd` — docs and scripts stopped claiming the repo is on shared NFS;
   `guard_host` now also protects `.qcow2` (it only checked `.vdi`);
   `fclean` no longer deletes the `.vm_path.<vm>` registry.
3. `3334c1f` — **`SIZE_B2B` drives everything.** `generate/partition_recipe.sh`
   computes the layout (floor + weighted surplus + cap, `/var` last with
   `-1`); `generate/feature_profile.sh` decides the install set (minimal /
   standard / full, `PROFILE=`, `FEATURES="+x -y"`, `AI_MODE`) and **checks
   it fits the layout mount by mount before the ISO is built**. Both land in
   the ISO through the single staging point in `create_custom_iso.sh`
   (`RECIPE-BEGIN/END` and `LUKS-BEGIN/END` markers; `features.conf` copied
   to `/etc/b2b/`). Guest scripts read the conf, install required features
   first, record each feature's measured `df` delta to
   `/etc/b2b/features.status`, and a failed base feature writes
   `/etc/b2b/PROVISION_FAILED` and prints `B2B-FEATURE-FAILED` on the
   console (the install watcher in `qemu_vm.sh` fails the build on it).
   `make partitions`, `make features`, tests for both generators.
4. `e964a96` — CI green under shfmt **and** hellish; `set_state` bug (a
   stray `tr` re-joined the feature list so overrides counted every feature
   as off); Docker's `/var` cost measured at 3300 MB (see below);
   `deploy_inception.sh` gained a `/var` pre-flight and a post-build
   `docker builder prune`.
5. `48eaf16` — **calibration from the first real build**: `/` held 2.7 GB
   before nvim on a 3.3 GB root, because the Debian base (~1.1 GB) was not
   in the cost table. Manifest rewritten to the measured split, root floor
   2816 / share 25 %, standard profile starts at **15 GB** (14 cannot hold it
   — measured, not chosen). `feature_end` now records a failed guard as
   `failed`, not `ok 0`.
6. `e5b5fa2`, `46e295d` — README reflects all of the above.
7. `6f019e6` — pre-flight no longer counts the ISOs into the budget (they are
   build inputs `make slim` removes; a rebuild failed its own check by
   exactly their size) and compares physical paths via `readlink -f`
   (`~/goinfre` vs `/goinfre/<login>` double-counted the VM).

## The mechanism, end to end

```text
SIZE_B2B (15) ─┬─> DISK_SIZE_MB = SIZE_B2B*1024          (Makefile)
               ├─> generate/partition_recipe.sh --recipe  (layout)
               ├─> generate/feature_profile.sh --check    (fits? else exit 1)
               │                             --conf     (features.conf)
               └─> SPACE_BUDGET_GB = SIZE_B2B + 1        (make space)
create_custom_iso.sh: LUKS swap -> RECIPE swap -> features check -> conf
   -> preseed.cfg (ISO root AND initrd) -> late_command copies conf to
   /target/etc/b2b/features.conf
b2b-setup.sh (in-target): base packages; webstack only if on; discard
   chain; /etc/b2b/layout from lvs; MOTD hook
first-boot-setup.sh: keepalive, UFW, fstrim, nvim, hellish, then webstack,
   node, pytools, devtools-extra, AI, docker — each gated + measured
```

Layout at the default (partman MB): root 4381, swap 2048, home 1075,
opt 569, srv 381, tmp 443, var-log 571, var 5371. Minimum disk 8 GB.
Profiles: minimal 8–14, standard 15–29, full 30+. Fit at 15 GB standard
(need / usable, MB): `/` 3050/3259, `/opt` 370/423, `/var` 3500/3996,
`/home` 740/799.

## Measured facts (do not re-derive these; extend them)

- First real build (`SIZE_B2B=15`, standard, 2026-09-11): `lsblk` matched
  the generator to the MB; `features.conf` correct; first boot ran in the new
  order; `/` used 2.7 GB before nvim → nvim guard tripped. Per-feature
  deltas recorded: nodejs 303 MB on `/`, docker engine 178 MB on `/var`,
  hellish 1 MB on `/home`.
- Inception with bonus on that VM: pre-flight `/var 5073 MB free`; **8
  images, 533 MB**; build cache pruned to 0; `/var` 1.1 G used / 4.5 G free
  after; `https://dlesieur.42.fr/` → 200 inside and from the host with a
  valid cert; static site 8090 → 200; proxy refuses other hosts. On the host
  that built the same stack, the build cache alone was **2.35 GB** — that is
  where the 3300 MB `/var` figure comes from (build peak, not steady state).
- Docker's steady state is ~0.5 GB; its build peak is what sizes `/var`.

## OPEN — in priority order

1. **Rebuild the VM on the calibrated layout and verify it.** The only VM
   built so far had the pre-calibration `/` (3.3 GB) and no nvim; the
   rebuild was killed by the wipe. From the fresh clone:
   `make all VM_NAME=b2r` (goinfre has ~48 GB free; the pre-flight must
   print `projected total, once slimmed 15.3 GB`). Then in the guest:
   `cat /etc/b2b/features.status` — every line `ok`, no
   `/etc/b2b/PROVISION_FAILED`, `nvim --version` works, `df -h` matches the
   layout above. **Feed the measured deltas back** into the manifest in
   `generate/feature_profile.sh` if any is off by more than a third
   (nvim's 350 MB on `/` and 300 MB on `/home` are still estimates).
2. **Redo the Inception Dockerfile fix** (lost with the wipe). In
   `Univers42/Inception` at `9e74aaa`, `srcs/requirements/nginx/Dockerfile`
   is unbuildable: inline `# comments` after line-continuation backslashes
   (lines 15, 19, 24, 26) end the continuation so `: "bust=…"` is parsed as
   an instruction, plus editor artifacts `\  +` (line 20) and `\<F6>`
   (line 21). Move the comments above the `RUN`, delete the artifacts,
   verify with `docker buildx build --check` in that directory (it will
   still fail resolving the `shell` build context — that is expected; the
   parse error must be gone). Commit it there; then
   `make inception SRC=/path/to/Inception VM_NAME=b2r` and expect the
   numbers under "Measured facts".
3. **Prove discard works** (the claim that fails silently). In the guest:
   `sudo dmsetup table sda5_crypt | grep -o allow_discards` (must print),
   `lsblk -D`; then on the host note `du -h` of the qcow2, in the guest
   write and delete a 2 GB file, `sudo fstrim -av`, re-measure on the host.
   The file must shrink. If not, the initramfs step in `b2b-setup.sh` is the
   first suspect. The guest sudo password is `passwd/user-password` in
   `preseeds/preseed.cfg`.
4. **Surface first-boot failures on the host.** `B2B-FEATURE-FAILED` is
   caught only during the install phase (`qemu_vm.sh` watcher). A base
   feature failing at first boot writes `/etc/b2b/PROVISION_FAILED` and the
   MOTD says so, but `make all` still exits 0. `make verify_guest` (or the
   pipeline's host phase) should read that file over ssh and fail.
5. **Old VM in sgoinfre.** 46 GB against the 15 GB cap; the owner wants it
   kept. Options are theirs: copy it to goinfre *while stopped* (the earlier
   copy was taken live and discarded), or apply the discard fix in place and
   `fstrim`. Do nothing here without an explicit go.
6. Small: `make slim COMPACT=1` is untested end to end; `utils/slim.sh`'s
   "fstrim reported nothing" heuristic is untested against a real trim.

## Verification tasks that make sense to hand out

Each is self-contained and states the expected result.

- `hellish tests/test_partition_recipe.sh` and
  `hellish tests/test_feature_profile.sh` → both exit 0 (36 and 46 checks).
  Add `SCRIPT_SH=hellish` in front if `$SCRIPT_SH` is unset.
- `make partitions SIZE_B2B=7` → exit 1, "SIZE_B2B must be at least 8".
  `make partitions SIZE_B2B=500` → root capped at 30720, var > 300 GB.
- `make features SIZE_B2B=14 PROFILE=standard` → exit 1, "fits from
  SIZE_B2B=15". `make features SIZE_B2B=15` → "✓ fits".
  `make features FEATURES=-nvim` → error, base feature.
- Stage a preseed through the real builder path without an ISO: extract the
  block between `echo "Copying preseed file to ISO root..."` and
  `echo "  ✓ features.conf staged` from `generate/create_custom_iso.sh`
  into a scratch script with `REPO_ROOT`, `PRESEED_FILE`, `ISO_DIR`, `LUKS`
  set; run for `SIZE_B2B=10`, `15`, `50 LUKS=OFF`. Expect 8 `lv_name{`,
  `var` last, `#   SIZE_B2B=<n>` header, 0 crypto keys in the OFF case,
  `features.conf` identical to `feature_profile.sh --conf`.
- Reword the `RECIPE-BEGIN` marker in a copy of `preseed.cfg` and stage
  again → the build must **refuse** ("did not land in the staged preseed").
- The four CI linters, exactly as `ci.yml` runs them, over
  `git ls-files '*.sh'`: shfmt v3.10 `-d -i 4`, shellcheck 0.10 `-e SC1091`,
  `bashate -i E006`, `markdownlint "**/*.md"`. All four must be clean; they
  were at `6f019e6`. Binaries can be fetched into a scratch dir (GitHub
  releases for shfmt/shellcheck, `pip install --user bashate`,
  `npx markdownlint-cli@0.45.0`).
- `make space` and the pre-flight with `VM_PATH` spelled both as
  `~/goinfre/born2root/disk_images` and `/goinfre/dlesieur/born2root/disk_images`
  → identical totals.

## Where things are

- Sizing: `generate/partition_recipe.sh`, `generate/feature_profile.sh`,
  markers in `preseeds/preseed.cfg`, splice + guards in
  `generate/create_custom_iso.sh` (search `RECIPE-BEGIN`, `feature_env`).
- Guest: `preseeds/b2b-setup.sh` (section 0 features, discard block,
  layout record, MOTD hook), `preseeds/first-boot-setup.sh` (section 0
  helpers `feature_on/begin/end/fail`, reordered sections).
- Host: `utils/space_budget.sh`, `utils/slim.sh`, `utils/luks_mode.sh`,
  `setup/host/qemu_vm.sh` (`find_iso`, drive flags, `di_feature_failed`
  in the watch loop), `setup/host/di_progress.sh`,
  `setup/host/deploy_inception.sh` (section 2b pre-flight, post-build prune).
- Tests: `tests/test_partition_recipe.sh`, `tests/test_feature_profile.sh`.
- Docs: `README.md` ("Disk Layout", "Installation profiles"), this file.
