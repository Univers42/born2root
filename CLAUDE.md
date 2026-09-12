# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this repository is

An automated builder for the 42 "Born2beRoot" Debian VM. One `make all`
downloads a Debian netinst ISO, injects a preseed plus setup scripts, creates a
VM (VirtualBox or QEMU/KVM), runs a ~20-minute unattended install with
LUKS+LVM, boots it headless, unlocks the disk from the host and writes the
host's `~/.ssh/config` so `ssh b2b` works. Everything that matters is
Bash-dialect shell driven by GNU Make. `a.out`, `main.c`, `issue` and
`vm_boot.log` at the root are stray leftovers, not part of the build.

## Commands

Plain `make` prints help; nothing builds by accident. `make -n all` is a real
dry run (the Makefile assigns `$(MAKE)` to `MAKE_BIN` so `-n` is honoured).

| Task | Command |
| --- | --- |
| Full build from nothing (~20 min, ~18 GB free needed) | `make all` |
| Destroy the VM and rebuild (`fresh` also deploys Inception) | `make re`, `make fresh` |
| Force a hypervisor / see which one would be picked and why | `BACKEND=qemu make all`, `make backend` |
| Build only the preseeded ISO (this is what CI does) | `make gen_iso` |
| Preview layout / feature set for a size, without building | `make partitions SIZE_B2B=50`, `make features SIZE_B2B=50` |
| Project footprint against the quota (fails when over) | `make space` |
| Status dashboard / follow the headless serial console | `make status`, `make console` |
| Boot an existing VM headless with LUKS unlock | `make start_vm` (VirtualBox), `make qemu_start` |
| Re-run a provisioner inside a built VM over SSH | `make nvim`, `make excalidraw`, `make devtools`, `make claude_code`, `make hellish_plugins`, `make provision`, `make shell_vm` |
| Run the hellish release binary in a Debian trixie container | `make -C docker shell` |

`make all` runs `prepare` first: `make deps`, then
`git pull --autostash --ff-only origin main`, then downloads the hellish
release binary to `dist/hellish` (`make shell`). Pin it with
`HELLISH_VERSION=v2.7.6`.

### Tests

No runner target. Each file is standalone, prints `ok`/`FAIL` lines and exits
non-zero on failure:

```bash
bash tests/test_partition_recipe.sh      # ~1 s
bash tests/test_feature_profile.sh       # ~12 s
for t in tests/test_*.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done
```

All `tests/test_*.sh` are host-side regression tests that need no VM: the
`utils/*.sh` they cover expose override hooks (fake sudo, port fixtures, a
stand-in `VBoxManage`) exactly for this. Each header names the real bug it pins
down; read it before changing the code under test. `tests/wp_apparmor_test.sh`,
`wordpress_attack_defense.sh` and `wordpress_apparmor_fix_demo.sh` run inside
the guest.

### Lint (what CI enforces, in this order, fail-fast)

```bash
find . -type f -name "*.sh" -print0 | xargs -0 shellcheck -e SC1091
find . -type f -name "*.sh" -exec bashate -i E006 {} +
find . -type f -name "*.sh" -exec shfmt -d -i 4 {} +     # shfmt -w -i 4 to fix
markdownlint "**/*.md"                                    # MD013: 80 columns
make --dry-run all
```

Shell scripts are indented with 4 spaces (CI's `shfmt -i 4` wins over the tab
setting in `.editorconfig`); the Makefile uses tabs. `.shellcheckrc` disables
SC1008 because of the non-standard shebang.

## The shell every script runs under

All `.sh` files have `#!/usr/bin/env hellish`. hellish is a bash-compatible
shell (github.com/Univers42/hellish) that is also the guest's login shell. The
scripts are written in Bash dialect (arrays, `local`, `BASH_SOURCE`) and run
fine under `bash script.sh`. The Makefile picks one interpreter at parse time
(`SCRIPT_SH`): the shell make was launched from if it passes
`tools/launcher_probe.sh`, else hellish, else bash, and sets `SHELL` to it so
recipes and scripts share it. Override with `make ... SCRIPT_SH=/bin/bash`.
A script that spawns a sibling script uses `"${SCRIPT_SH:-bash}"`, never a
hardcoded `bash`.

## Architecture

### Host side vs guest side

- Host side (runs on your machine): `Makefile`, `generate/`, `setup/host/`,
  `setup/install/vms/`, `utils/`, `unlock_vm.sh`.
- Guest side (baked into the ISO, runs inside the VM): `preseeds/`, and the
  provisioners `setup/install/{nvim,hellish,tools,ai}/*.sh`, which
  `first-boot-setup.sh` runs from `/root` and `setup/host/provision_vm.sh`
  re-pushes over SSH later.
- Ad hoc and mostly historical: `diagnostic/`, `fixes/`, `management_tools/`,
  `monitore/`, `wordpress/`, `bak_conf/`, the other root-level scripts.

### `make all`, end to end

1. Guards, before anything expensive: `no_root` (refuses `sudo make all`, which
   would bake root's SSH key and leave root-owned files), the LUKS banner,
   `utils/space_budget.sh --preflight`, `setup/host/select_backend.sh`
   (VirtualBox vs QEMU; decision on stdout, reasons on stderr), and
   `utils/vm_path.sh` (is `$VM_PATH/$VM_NAME` writable, and if not, why).
2. `make gen_iso` runs `generate/create_custom_iso.sh`: downloads the current
   netinst from cdimage.debian.org, extracts it with xorriso, stages
   `preseed.cfg` (see the marker blocks below), the three `preseeds/*.sh`, the
   provisioners, `features.conf`, `dist/hellish` as `custom_shell.bin` and your
   `~/.ssh/id_*.pub`, appends `preseed.cfg` to `initrd.gz` as a second cpio
   archive, and rebuilds the ISO. The output name carries a LUKS suffix so
   `LUKS=ON` and `LUKS=OFF` ISOs are never confused. `.gen_iso.lock` serialises
   concurrent builds.
3. Disk, unattended install, first boot, host config: `generate/orchestrate.sh`
   (VirtualBox, live TUI dashboard) or `setup/host/qemu_pipeline.sh` calling
   `setup/host/qemu_vm.sh` (QEMU). Same five phases, byte-identical ISO, same
   guest. Only the hypervisor differs.
4. `setup/host/inception_host_access.sh` teaches the host browsers to resolve
   `<login>.42.fr` without root (Firefox `network.dns.localDomains`, Chromium
   `--host-resolver-rules`).

The pipeline is headless. The VM's COM1 is a file, the guest boots with
`console=ttyS0`, and the orchestrator reads installer progress from it. LUKS is
unlocked from the host by typing into the virtual keyboard
(`VBoxManage controlvm keyboardputstring` plus scancode `1c 9c`, or QEMU
monitor `sendkey`). Readiness means the SSH banner answered, not an open port:
NAT accepts connections whether or not the guest is listening.

### Inside the guest

`preseed.cfg`'s `late_command` copies the scripts into `/target` and runs
`b2b-setup.sh` via `in-target`. That is a chroot with no systemd and limited
network, so it does every mandatory Born2beRoot setting (SSH on 4242, UFW,
sudo, pwquality, AppArmor, cron monitoring, TRIM via crypttab, `lvm.conf` and
`fstrim.timer`) from Debian repo packages only, before any network download.
`first-boot-setup.sh` runs once via an `@reboot` crontab and self-deletes:
Docker, WordPress, third-party tools, nvim, hellish plugins. It sources
`/etc/b2b/features.conf`, installs required features first, writes the measured
cost of each to `/etc/b2b/features.status` (one line per mount a feature
touches), and on a required feature failing prints `B2B-FEATURE-FAILED` to the
serial console, which fails `make all`, and records why in
`/etc/b2b/PROVISION_FAILED`. Provisioners are run through `run_logged`, never
`provisioner | tee log`: without `pipefail` a pipeline's status is `tee`'s, so
every provisioner used to report success whatever it did.

Everything the editor needs is installed **at build time and then verified**:
`install_nvim.sh` and `install_nvim_extras.sh` retry the `vim.pack` download up
to three times, install the tree-sitter parsers with a wait (nvim-treesitter's
`main` installs asynchronously and a headless Neovim exits under it), then run
`/usr/local/lib/b2b/nvim-verify.lua`, which exits 1 when a declared plugin,
parser, language server or prebuilt binary is missing. A headless
`vim.pack.add` is also wrapped with `confirm = false`, because its default is
to ask. `install_excalidraw.sh` bundles the Excalidraw editor into
`/opt/excalidraw` and smoke-tests its server before returning.

### One number: `SIZE_B2B`

`SIZE_B2B` (GB, default 15 = the school quota) derives everything:

- `DISK_SIZE_MB` and `SPACE_BUDGET_GB` (`SIZE_B2B + 1`) in the Makefile.
- The partition layout, from `generate/partition_recipe.sh`: every volume has a
  floor, a weighted share and a cap, `/var` is declared last with `-1` so
  partman's remainder lands where Docker grows. Below 8 GB it refuses.
- What gets installed, from `generate/feature_profile.sh`: minimal 8–14,
  standard 15–29, full 30+, overridable with `PROFILE=` and
  `FEATURES="+docker -pytools"`, checked mount by mount against that layout
  with 20% headroom. A set that does not fit fails the ISO build and names the
  smallest size that would. `full` is not a synonym for `standard`: today it
  is what claude-code lives in, because its 320 MB does not fit the 289 MB the
  standard set leaves on `/` at the default 15 GB.

Two marker contracts in `preseeds/preseed.cfg` matter when editing it. The
`RECIPE-BEGIN`/`RECIPE-END` block is the generator's output for the default size
and is regenerated at ISO build time; after changing `partition_recipe.sh`,
paste `bash generate/partition_recipe.sh --recipe` back into it or
`tests/test_partition_recipe.sh` fails. The `LUKS-BEGIN`/`LUKS-END` block is
what `LUKS=OFF` rewrites. Feature cost estimates in `feature_profile.sh` are
meant to be corrected from a built guest's `features.status`.

### Two backends, one guest

Everything a backend writes lives under `$VM_PATH/$VM_NAME/`: the `.vdi` or
`.qcow2`, pidfile, monitor socket, `serial.log`, and the `.built-on`,
`.installed` and `.phase` stamps. `VM_PATH` defaults to `disk_images/` and is
remembered in `disk_images/.vm_path.<vm>`, so a relocated VM needs no repeated
`VM_PATH=`. Host ports (SSH from 4242, HTTP from 8082, HTTPS from 8443, and the
app ports) are allocated by `utils/host_ports.sh`, walking past ports already in
use, so never assume 4242: read the port back the way `orchestrate.sh` and
`provision_vm.sh` do.

### Guards on destructive paths

- `install_vm_debian.sh` keeps an existing disk, so `make all` on a built
  machine boots the old system. A real reinstall needs `make re`.
- `qemu_install` refuses to reinstall over a qcow2 larger than 1 GB
  (`FORCE_INSTALL=1` to mean it).
- `guard_host` refuses `rm_disk_image`, `fclean` and `re` when `.built-on` names
  another machine (`FORCE_HOST=1`).
- `fclean` empties `VM_PATH` but keeps the directory and the `.vm_path.*`
  registry.

## Conventions

- Conventional Commits, optional scope (`iso`, `host`, `vm`, `scripts`,
  `preseed`); branches named `type/short-description`; PRs against `main`.
- Comments are block comments placed before a function or logic block and they
  explain the why, the trick, or the bug that motivated the code, usually with
  the measurement that proved it. The existing headers set the bar: read the
  top of any `utils/*.sh` or `setup/host/*.sh` before editing it, and keep the
  header true when the behaviour changes.
- Fail before the 20-minute install rather than during it. Refusals name the
  fix (`make all SIZE_B2B=15`, `FORCE_HOST=1`), and a warning that would scroll
  past mid-build is an error instead.
- Host scripts must not assume a distro or root. sudo is offered only when a
  terminal is attached and only for the exact step that needs it.
- Idempotency: `make all` on an already-built machine must boot it, not fail.
- Credentials are the temporary defaults listed in the README. The LUKS
  passphrase comes from `VM_PASS` or `vm_pass.txt`. Add no hardcoded secrets.
- `doc/` holds deep dives (CI architecture, port forwarding, host domain
  access, the VS Code SSH timeout fix). `doc/README.md` is a Born2beRoot
  command cheat sheet, not an index.
