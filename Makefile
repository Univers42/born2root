# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: Invalid date        by ut down the       #+#    #+#              #
#    Updated: 2026/08/29 16:54:29 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# ============================================================================ #

# =========@@ Config @@=========================================================
VM_NAME      ?= debian
# Which hypervisor executes the VM. The GUEST is identical either way -- same
# preseeded ISO, same LUKS+LVM layout, same b2b-setup.sh, same first boot --
# so this only decides what runs the machine, never what is inside it.
#   auto        pick whatever this machine can actually do, and ask only when
#               both are available and there is a terminal to ask on
#   virtualbox  the original path; needs the vboxdrv kernel module (root)
#   qemu        KVM; needs no module, only access to /dev/kvm, so it works as
#               an ordinary user on machines where VirtualBox cannot
BACKEND      ?= auto
# ── Which shell interprets the scripts ──────────────────────────────────────
# make parses the Makefile; the .sh files it calls are interpreted by a shell.
# Run them with the shell you launched make FROM -- hellish when that is your
# shell -- and fall back to bash. (The scripts' own shebang is
# `#!/usr/bin/env hellish`, for when they are started by hand; make never
# consults it, so a host without hellish still builds the VM under bash.)
# The launcher is make's parent process; a
# candidate is used only if it can run the scripts' bash-isms (arrays, local,
# BASH_SOURCE) and says so (BASH_VERSION -- zsh passes the rest of the probe
# and then fails on the first unmatched glob), so `make all` can never pick a
# shell that would choke on them.
# Override with `make ... SCRIPT_SH=/path/to/shell`. Exported, so recursive
# makes and the scripts themselves inherit the same choice without re-probing.
ifeq ($(origin SCRIPT_SH),undefined)
# No shell takes part in finding the launcher. GNU make execs a $(shell ...)
# line that has no shell metacharacters directly, so `cat /proc/self/stat` is
# cat itself, and its 4th field is make's pid; make's own stat gives its
# parent; that parent's comm is the launcher. Each candidate is then asked to
# run tools/launcher_probe.sh itself: it prints B2R_SH=<its path> only when it
# is a shell that can interpret the scripts (bash-isms, BASH_VERSION), so a
# candidate that is no shell at all leaves nothing. The launcher and the
# login shell are only tried when their name is a shell's (a `timeout`,
# an editor or a sub-make in between would otherwise print its usage).
# They are tried one at a time -- $(if) expands only the branch it takes --
# so a hellish launch never starts bash even to ask it.
# Until this line every $(shell) would otherwise have been /bin/sh -c: a run
# launched from hellish now starts no other shell at all, which is what
# tests/born2root_shell_audit.sh in the hellish tree checks from the outside.
_b2r_ppid    := $(word 4,$(shell cat /proc/$(word 4,$(shell cat /proc/self/stat))/stat))
_b2r_launcher := $(shell cat /proc/$(_b2r_ppid)/comm)
_b2r_login   := $(notdir $(shell printenv SHELL))
_b2r_shells   := hellish hellish.real bash zsh dash sh ksh mksh ash busybox
_b2r_try = $(if $(filter $(_b2r_shells),$(notdir $(1))),$(filter B2R_SH=%,$(shell $(1) tools/launcher_probe.sh)))
_b2r_found := $(call _b2r_try,$(_b2r_launcher))
_b2r_found := $(if $(_b2r_found),$(_b2r_found),$(call _b2r_try,$(_b2r_login)))
_b2r_found := $(if $(_b2r_found),$(_b2r_found),$(call _b2r_try,hellish))
_b2r_found := $(if $(_b2r_found),$(_b2r_found),$(call _b2r_try,bash))
SCRIPT_SH := $(patsubst B2R_SH=%,%,$(firstword $(_b2r_found)))
SCRIPT_SH := $(if $(strip $(SCRIPT_SH)),$(strip $(SCRIPT_SH)),bash)
endif
export SCRIPT_SH
# The recipes themselves, too. make would otherwise run every recipe line
# under /bin/sh and only hand the scripts to $(SCRIPT_SH): the loops, the
# printf banners and the `[ ... ] && ...` glue between two scripts would be
# dash in a run that claims to be hellish. One shell for both, from here on:
# every $(shell ...) below this line, VM_PATH's included, runs under it too.
SHELL := $(SCRIPT_SH)

# Where the VM lives. VirtualBox remembers a VM's disk itself; for QEMU the
# last create/boot recorded it (utils/vm_path.sh remember_vm_dir), so after a
# `make all VM_PATH=/mnt/storage/qemu` no later `make qemu_*` needs VM_PATH.
# An explicit VM_PATH (command line or environment) always wins.
ifeq ($(origin VM_PATH),undefined)
VM_PATH      := $(shell cat $(CURDIR)/disk_images/.vm_path.$(VM_NAME) 2>/dev/null || echo $(CURDIR)/disk_images)
endif
VM_SCRIPT    := ./setup/install/vms/install_vm_debian.sh
ISO_BUILDER  := ./generate/create_custom_iso.sh
PRESEED_FILE := preseeds/preseed.cfg
RM           := rm -rf
VMS_ISO_TAR  := vms_iso.tar

# Inception (the project that runs *inside* this VM). LOGIN drives the
# subject-mandated domain; SRC optionally points `make inception` at a
# host-side copy of the repo instead of cloning from GitHub.
LOGIN        ?= dlesieur
DOMAIN       ?= $(LOGIN).42.fr
SRC          ?=

# Force rebuilding the preseed ISO even if it already exists.
# `make all` sets this automatically so the ISO always matches the latest scripts/binaries.
FORCE_ISO ?= 0

# Optional: set a custom default login shell inside the VM.
# Default is the hellish binary downloaded from the upstream GitHub release
# (see setup/fetch_hellish.sh) — no submodule, no compile.
# To keep bash, override with an empty value:
#   make gen_iso CUSTOM_SHELL_PATH=
CUSTOM_SHELL_PATH ?= dist/hellish

# Which hellish release to bake in. Empty = always resolve the newest release.
# Pin a tag to freeze it (and to skip the GitHub API entirely):
#   make all HELLISH_VERSION=v2.7.6
HELLISH_VERSION ?=
# Force a re-download even when the cached copy already matches:
#   make shell HELLISH_REFRESH=1
HELLISH_REFRESH ?=

# Neovim provisioning (see setup/install/nvim/install_nvim.sh).
# Debian 13 ships neovim 0.10.4; kickstart.nvim's master branch is built on
# `vim.pack`, which only exists from 0.12 — so the upstream release tarball is
# installed under /opt instead of the distro package. Pinned for reproducible
# builds; NVIM_VERSION=latest tracks the newest release instead.
#   make nvim NVIM_VERSION=latest
NVIM_VERSION ?=
# Which users inside the VM get a kickstart config (space separated).
NVIM_USERS ?=

# Disk size for a NEW VM, in MB. Only affects a VM being created: an existing
# disk is kept.
#
# This used to be 122880 (120GB), on the theory that a dynamically-allocated
# disk is a ceiling rather than an allocation and so costs nothing until used.
# That theory was wrong here and the bill came to 42.7GB for a guest holding a
# small fraction of it. A thin disk only stays thin while something tells it
# which blocks are free, and on a LUKS guest nothing did: dm-crypt discards
# unless the mapping is opened with allow-discards, so every block the guest
# ever touched stayed allocated forever. preseeds/b2b-setup.sh now wires TRIM
# through crypttab, lvm.conf and fstrim.timer, which is what makes the host
# file track real usage instead of high-water mark.
#
# With that fixed the virtual size means what it says: a hard ceiling on what
# this VM can cost. 14336MB (14GB) is chosen against a 15GB school quota for
# the whole project — see `make space`, which fails a build that exceeds it.
# The recipe in preseeds/preseed.cfg fully allocates the group, with /var last
# and unpinned so the remainder lands where Docker needs it. Raising this
# number therefore grows /var; to move space between volumes afterwards use
# `lvreduce -r` on one and `lvextend -r` on another.
DISK_SIZE_MB ?= 14336

# Encrypt the guest's LVM with LUKS. ON is the default and is the only mode
# that satisfies the born2root mandatory requirement — the VM you hand in must
# be built this way.
#
# LUKS=OFF builds an unencrypted guest. It exists to measure disk behaviour
# with encryption out of the way: without dm-crypt in the path, freed blocks
# are zeroes rather than ciphertext, so discard needs no crypttab/initramfs
# step and `qemu-img convert` can compact the image offline. Handy for space
# experiments, never for a submission — `make all LUKS=OFF` says so loudly.
#
# This is baked into the ISO at build time (the preseed lives inside the
# initrd), so changing it requires a new ISO. The two modes write different
# ISO filenames so a cached one is never silently reused across modes.
LUKS ?= ON

# The whole project — source, ISOs and the VM disk — must fit in this many GB.
# 15 is the school's shared-storage cap. `make space` reports the breakdown and
# fails when it is exceeded; `make all` checks it before building anything.
# Raise it for one run with SPACE_BUDGET_GB=25 make ...
SPACE_BUDGET_GB ?= 15

# `make slim COMPACT=1` also rewrites the qcow2 without its unreferenced
# clusters. Off by default because it requires the VM to be stopped.
COMPACT ?= 0

# Override the VM's RAM (MB). Default is 25% of host RAM clamped to [2048,8192],
# which is sized to keep the HOST responsive. Raise it for a local model — the
# 2048 floor is below what any model needs, and AI_MODE=local will say so.
#   make re VM_RAM_MB=6144 AI_MODE=local
VM_RAM_MB ?=

# Optional AI, baked into the ISO so first boot honours it (default: off).
#   off     nothing installed, nothing downloaded
#   client  Ollama CLI pointed at an endpoint elsewhere (10.0.2.2 = the host)
#   local   Ollama server + a model chosen to FIT this VM's RAM
# The model is computed, never guessed: a 27B model needs ~17GB and will be
# refused rather than left to thrash swap. See setup/install/ai/install_ai.sh.
AI_MODE ?= off
# Note: once connected to the VM via SSH, you can change the default shell for the user (e.g. dlesieur) with:
# sudo usermod -s /bin/bash dlesieur && getent passwd dlesieur

# Normalize to absolute path so ISO builder works from any cwd.
ifneq ($(strip $(CUSTOM_SHELL_PATH)),)
CUSTOM_SHELL_PATH := $(abspath $(CUSTOM_SHELL_PATH))
endif

# Colours (portable — works in bash/dash/zsh)
C_RESET  := \033[0m
C_BOLD   := \033[1m
C_GREEN  := \033[32m
C_YELLOW := \033[33m
C_BLUE   := \033[34m
C_RED    := \033[31m
C_CYAN   := \033[36m

# =========@@ Main target @@===================================================
.PHONY: all prepare pull shell deps extpack check_system check_driver guard_host backend fix_hwe fix_app_ports gen_iso setup_vm start_vm status help \
        clean fclean re poweroff list_vms prune_vms console serial_log \
        list_vms_iso extract_isos push_iso pop_iso rm_disk_image bstart_vm gui_vm \
        host_access host_access_undo inception verify_access verif_access fresh \
        nvim hellish_plugins shell_vm provision nvim_health global_scope devtools ai \
        qemu_install qemu_start qemu_stop qemu_status qemu_console qemu_watch verify_guest \
        qemu_create qemu_kill qemu_restart qemu_reset qemu_pause qemu_resume qemu_unlock \
        qemu_screenshot qemu_ssh qemu_ssh_config qemu_list qemu_monitor no_root \
        space slim

# Plain `make` prints the help instead of building. Building this project means
# downloading an ISO, creating a VM and running a ~20-minute install — too much
# to kick off by accident from a bare `make`. Use `make all` to build.
.DEFAULT_GOAL := help

# The orchestrator needs to invoke make for its sub-steps, so it is handed the
# make command as an argument. That argument must NOT be written as $(MAKE):
# GNU make scans the *unexpanded* recipe text for the literal string "$(MAKE)"
# and, on finding it, runs that line even under -n / -t / -q — the recursion
# escape hatch. With $(MAKE) spelled out here, `make -n all` was not a dry run
# at all: it really executed the orchestrator, which really touched VirtualBox.
# Assigning it to another variable first leaves no "$(MAKE)" in the recipe, so
# -n behaves the way anyone typing it expects.
MAKE_BIN := $(MAKE)

# VM_PATH is checked before either pipeline runs, so a root-owned storage
# directory is reported -- and, with permission, fixed with sudo -- before the
# ISO build rather than minutes after it. See utils/vm_path.sh.
# `sudo make all` "works" and quietly builds the wrong VM: the ISO gets ROOT's
# ~/.ssh key (so `ssh b2b` asks for a password), ~/.ssh/config is root's, and
# the disk, pidfile and monitor socket end up root-owned. Nothing in the build
# needs root; when VM_PATH does, make all asks for sudo for exactly that step.
# Same check as qemu_vm.sh create/install/start (utils/vm_path.sh refuse_sudo_build).
no_root:
	@$(SCRIPT_SH) utils/vm_path.sh --no-root "make all VM_PATH=$(VM_PATH)"

all: no_root prepare
	@$(SCRIPT_SH) utils/luks_mode.sh --banner "$(LUKS)" || exit 1
	@SPACE_BUDGET_GB="$(SPACE_BUDGET_GB)" VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" \
		$(SCRIPT_SH) utils/space_budget.sh --preflight "$(DISK_SIZE_MB)" || exit 1
	@backend=$$(BACKEND="$(BACKEND)" $(SCRIPT_SH) setup/host/select_backend.sh "$(BACKEND)") || exit 1; \
	$(SCRIPT_SH) utils/vm_path.sh "$(VM_PATH)" "$(VM_NAME)" || exit 1; \
	if [ "$$backend" = "qemu" ]; then \
		CUSTOM_SHELL_PATH="$(CUSTOM_SHELL_PATH)" FORCE_ISO=1 AI_MODE="$(AI_MODE)" \
		DISK_SIZE_MB="$(DISK_SIZE_MB)" VM_RAM_MB="$(VM_RAM_MB)" VM_NAME="$(VM_NAME)" \
		VM_PATH="$(VM_PATH)" MAKE_BIN="$(MAKE_BIN)" LUKS="$(LUKS)" \
			$(SCRIPT_SH) setup/host/qemu_pipeline.sh; \
	else \
		$(MAKE_BIN) --no-print-directory check_driver && \
		CUSTOM_SHELL_PATH="$(CUSTOM_SHELL_PATH)" FORCE_ISO=1 AI_MODE="$(AI_MODE)" \
		DISK_SIZE_MB="$(DISK_SIZE_MB)" VM_RAM_MB="$(VM_RAM_MB)" LUKS="$(LUKS)" \
			$(SCRIPT_SH) generate/orchestrate.sh "$(VM_NAME)" "$(MAKE_BIN)"; \
	fi
	@VM_NAME="$(VM_NAME)" INCEPTION_DOMAIN="$(DOMAIN)" $(SCRIPT_SH) setup/host/inception_host_access.sh

# Which backend would `make all` pick right now, and why?
backend:
	@BACKEND="$(BACKEND)" $(SCRIPT_SH) setup/host/select_backend.sh "$(BACKEND)" >/dev/null

# =========@@ QEMU/KVM backend @@=============================================
# The same VM, run by QEMU instead of VirtualBox. Useful on its own when you
# want to drive the phases by hand rather than through `make all`.
QEMU_ENV = VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" \
	DISK_SIZE_MB="$(DISK_SIZE_MB)" VM_RAM_MB="$(VM_RAM_MB)" LUKS="$(LUKS)"

# Boots the ISO and runs the unattended install, which REFORMATS the disk.
# A qcow2 that has grown past ~1GB already holds an installed system, so
# running this on it would destroy a working VM -- the same reasoning as
# install_vm_debian.sh keeping an existing VDI. Refuse, and say how to mean it.
qemu_install:
	@dir="$(VM_PATH)/$(VM_NAME)"; disk="$$dir/$(VM_NAME).qcow2"; \
	sz=0; [ -f "$$disk" ] && sz=$$(stat -c %s "$$disk" 2>/dev/null || echo 0); \
	installed=0; [ -f "$$dir/.installed" ] && installed=1; \
	[ "$$sz" -gt 1073741824 ] && [ ! -f "$$dir/.phase" ] && installed=1; \
	if [ "$$installed" = 1 ] && [ "$(FORCE_INSTALL)" != "1" ]; then \
		printf "$(C_RED)✗$(C_RESET) Refusing to reinstall over an existing system.\n\n"; \
		printf "    disk : %s (%s MB, %s)\n" "$$disk" "$$((sz / 1048576))" \
			"$$([ -f "$$dir/.installed" ] && echo "installed $$(cat "$$dir/.installed")" || echo "no stamp, size says installed")"; \
		printf "\n  The installer reformats the disk, so this would destroy the VM\n"; \
		printf "  that is already installed there.\n\n"; \
		printf "    $(C_BOLD)make qemu_start$(C_RESET)                    boot what is already there\n"; \
		printf "    $(C_BOLD)make qemu_install FORCE_INSTALL=1$(C_RESET)  wipe it and install again\n\n"; \
		exit 1; \
	fi
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh create
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh install

qemu_start:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh start
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh ssh-config

qemu_stop:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh stop

qemu_status:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh status

qemu_console:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh console

# Re-attach the install progress tracker (Ctrl+C only ever detaches it).
qemu_watch:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh watch

# Just the disk (qemu_install = create + install).
qemu_create:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh create

qemu_kill:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh kill

qemu_restart:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh restart
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh ssh-config

# Hard reset, pause and resume go through the QEMU monitor.
qemu_reset:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh reset

qemu_pause:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh pause

qemu_resume:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh resume

# Type the LUKS passphrase at the guest (qemu_start does this itself).
qemu_unlock:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh unlock

# The VGA screen, where the LUKS prompt and boot errors live.
qemu_screenshot:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh screenshot

# A shell in the guest on the port it actually got -- or one command:
#   make qemu_ssh CMD="uname -a"
qemu_ssh:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh ssh $(CMD)

qemu_ssh_config:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh ssh-config

# Every QEMU guest on this host, whoever started it, from whatever VM_PATH.
qemu_list:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh list

# Any QEMU monitor command:   make qemu_monitor CMD="info block"
qemu_monitor:
	@$(QEMU_ENV) $(SCRIPT_SH) setup/host/qemu_vm.sh monitor "$(or $(CMD),info status)"

# Prove the guest is the same whichever backend built it: partitions, LUKS,
# LVM, UFW, the policy files and the login shell all come from the preseeded
# ISO. Run it on both and diff the output.
verify_guest:
	@BACKEND_LABEL="$(BACKEND)" $(SCRIPT_SH) setup/host/verify_guest_parity.sh

# Prepare everything needed for a smooth `make all` experience:
# - check + install host dependencies (VirtualBox, xorriso, gcc, libreadline-dev, …)
# - update repo (if this is a git checkout)
# - download the latest published hellish release binary
#
# There is no submodule step any more: sh42 was the only one, and its whole
# nested tree — libft, ft_malloc, philosopher, scripts — existed purely to
# compile a binary we now download. A fresh clone needs no submodules and no
# SSH key (.gitmodules used git@github.com:); the release is plain HTTPS.
prepare: deps pull shell

# NOTE on --autostash: this used to be a hand-rolled `git stash` / `git stash
# pop` pair around the pull, and the two were NOT symmetric. `git stash` on a
# CLEAN tree saves nothing and creates no entry, but the pop ran unconditionally
# -- so it popped whatever unrelated entry happened to be on top of the stack.
# A stash left over from days ago was silently applied on top of an up-to-date
# checkout, and `make all` died in conflict markers over work that was already
# committed. Reproduced deterministically: stash something, commit past it, run
# the pair on the now-clean tree, and the stale WIP is back in your files.
#
# git's own --autostash has no such gap: it stashes only when there is something
# to stash, and restores exactly what it stashed, or nothing at all.
pull:
	@$(SCRIPT_SH) -c '\
	if [ -d .git ]; then \
		printf "$(C_BLUE)▶$(C_RESET) Pulling latest from origin/main...\n"; \
		if git pull --autostash --ff-only origin main 2>/dev/null; then \
			printf "$(C_GREEN)✓$(C_RESET) Repository up to date\n"; \
		else \
			printf "$(C_YELLOW)⚠$(C_RESET)  Fast-forward failed — merging...\n"; \
			git pull --autostash origin main 2>/dev/null || \
				printf "$(C_YELLOW)⚠$(C_RESET)  git pull failed (working offline?)\n"; \
		fi; \
		if [ -n "$$(git diff --name-only --diff-filter=U)" ]; then \
			printf "$(C_RED)✗$(C_RESET) your local changes conflict with what was just pulled\n"; \
			git diff --name-only --diff-filter=U | sed "s/^/    /"; \
			printf "    Resolve the conflict markers above, then: git add <files> && make all\n"; \
			printf "    Your work is still in the stash too: git stash list\n"; \
			exit 1; \
		fi; \
	fi'

# Sync + update ALL submodules (any depth) to the latest upstream commit, and repair
# orphan gitlinks (submodule paths an upstream repo committed without a .gitmodules
# entry, e.g. libft's srcs/memory/ft_malloc). Fully auto-detected — see the script.
#
# NOTE: no longer part of `prepare`, and this repo now registers NO submodules
# (sh42 was removed in favour of the downloaded hellish release). Kept as
# generic machinery in case one is ever added back; it is a no-op today.
update:
	@$(SCRIPT_SH) setup/update_submodules.sh


# Fetch the custom shell: download the published hellish release binary.
# This replaced a full submodule checkout + ~550-file compile. The asset is
# the same one `hellish --update` pulls, verified against its published
# SHA-256 before it is allowed near the ISO.
#
# To build from source instead, clone hellish yourself and point the ISO at it:
#   git clone --recursive https://github.com/Univers42/hellish
#   make -C hellish all OPT=1        # `all` matters: its default goal is `help`
#   make all CUSTOM_SHELL_PATH=hellish/build/bin/hellish
shell:
	@HELLISH_VERSION="$(HELLISH_VERSION)" HELLISH_REFRESH="$(HELLISH_REFRESH)" \
		OUT_BIN="$(CUSTOM_SHELL_PATH)" $(SCRIPT_SH) setup/fetch_hellish.sh


# =========@@ Install host developer dependencies @@==========================
# Checks for: VirtualBox + ext-pack, xorriso, curl, gcc, libreadline-dev,
# python3, git, openssh-client, make.
# Missing packages are installed via `sudo apt install` WITHOUT -y so the
# user reviews and confirms the apt plan themselves.
deps:
	@$(SCRIPT_SH) setup/install/check_deps.sh

# =========@@ VirtualBox Extension Pack (optional) @@=========================
# Deliberately NOT part of `make deps` / `make all`. The pack installs into
# /usr/lib/virtualbox, so it needs root, and a sudo prompt in the middle of the
# build is a trap: sudo asks for "password for dlesieur", which is also the VM's
# username, so the VM password gets typed in and the whole build looks broken.
#
# Nothing here uses the pack either. It adds USB 2.0/3.0 passthrough, VRDP,
# NVMe, PXE boot and VDI-level disk encryption; this VM runs on NAT networking,
# a SATA disk, guest-side LUKS and a serial console. Install it only if you want
# those extras:
extpack:
	@INSTALL_EXTPACK=1 $(SCRIPT_SH) setup/install/check_deps.sh

# =========@@ System compatibility pre-checks @@==============================
check_system:
	@$(SCRIPT_SH) -c '\
	ERRORS=0; \
	KERN=$$(uname -r); \
	printf "$(C_BLUE)▶$(C_RESET) Pre-flight checks (running kernel: $$KERN)\n"; \
	VBOX_VER=""; \
	VBOX_MAJOR=0; \
	if command -v VBoxManage >/dev/null 2>&1; then \
		VBOX_VER=$$(VBoxManage --version 2>/dev/null | awk "/^[0-9]+\\.[0-9]+/ {print \$$1; exit}" | cut -d r -f1); \
		VBOX_MAJOR=$$(printf "%s\n" "$$VBOX_VER" | awk -F. "{if (\$$1 ~ /^[0-9]+$$/) print \$$1 \$$2; else print 0}"); \
		VBOX_MAJOR=$${VBOX_MAJOR:-0}; \
	fi; \
	HWE_PKGS=$$(dpkg -l 2>/dev/null \
		| awk "/^ii.*linux-image-[0-9]/{print \$$2}" \
		| grep -E "linux-image-6\.(1[3-9]|[2-9][0-9])\.|linux-image-[7-9]\." \
		| tr "\n" " "); \
	if [ -n "$$HWE_PKGS" ] && [ "$$VBOX_MAJOR" -lt 71 ]; then \
		printf "$(C_YELLOW)⚠$(C_RESET)  Incompatible HWE kernel(s) installed: $$HWE_PKGS\n"; \
		printf "$(C_YELLOW)  VirtualBox 7.0.x DKMS cannot build against these kernels and\n$(C_RESET)"; \
		printf "$(C_YELLOW)  may break entirely even when booting an older kernel.\n$(C_RESET)"; \
		printf "$(C_YELLOW)  Fix:$(C_RESET) make fix_hwe\n"; \
	elif [ -n "$$HWE_PKGS" ]; then \
		printf "$(C_GREEN)✓$(C_RESET) VirtualBox $$VBOX_VER supports installed HWE kernel(s)\n"; \
	fi; \
	if ! test -c /dev/vboxdrv 2>/dev/null; then \
		printf "$(C_RED)✗$(C_RESET) /dev/vboxdrv missing — VirtualBox kernel driver not loaded\n"; \
		ERRORS=$$((ERRORS+1)); \
		if command -v dkms >/dev/null 2>&1; then \
			DKMS_BAD=$$(dkms status 2>/dev/null | grep -i vbox | grep -iv installed | head -5); \
			if [ -n "$$DKMS_BAD" ]; then \
				printf "$(C_RED)  Broken DKMS entries:$(C_RESET) $$DKMS_BAD\n"; \
				printf "$(C_YELLOW)  Fix:$(C_RESET) make fix_hwe\n"; \
			else \
				printf "$(C_YELLOW)  Run:$(C_RESET) make fix_hwe\n"; \
			fi; \
		else \
			printf "$(C_YELLOW)  Run:$(C_RESET) make fix_hwe\n"; \
		fi; \
	else \
		printf "$(C_GREEN)✓$(C_RESET) /dev/vboxdrv OK\n"; \
	fi; \
	if command -v code >/dev/null 2>&1; then \
		if ! code --list-extensions 2>/dev/null | grep -qi "ms-vscode-remote.remote-ssh"; then \
			printf "$(C_YELLOW)⚠$(C_RESET)  VS Code Remote-SSH extension not installed on host\n"; \
			printf "$(C_YELLOW)  Fix:$(C_RESET) code --install-extension ms-vscode-remote.remote-ssh\n"; \
		else \
			printf "$(C_GREEN)✓$(C_RESET) VS Code Remote-SSH extension present\n"; \
		fi; \
	else \
		printf "$(C_YELLOW)⚠$(C_RESET)  code not in PATH — verify ms-vscode-remote.remote-ssh is installed\n"; \
	fi; \
	if [ "$$ERRORS" -gt 0 ]; then \
		printf "$(C_RED)✗$(C_RESET) Pre-flight failed ($$ERRORS error(s)). Fix the above then retry.\n"; \
		exit 1; \
	fi; \
	printf "$(C_GREEN)✓$(C_RESET) All pre-flight checks passed\n"'

# =========@@ Can THIS machine run a VM at all? @@=============================
# The VirtualBox kernel driver is per-machine state. A 42 home directory is on
# NFS and follows you between workstations; vboxdrv does not. So a clone that
# builds on one machine can be unable to start a VM on the next one with
# nothing in the repo having changed -- and the old failure mode for that was a
# green "VirtualBox ready" row followed a minute later by a wall of VBoxManage
# errors, because `VBoxManage --version` prints its "module is not loaded"
# warning on stdout and it got captured as the version string.
#
# This says so up front instead, names the machine, and never changes anything.
#   make check_driver              diagnose this machine
#   make all SKIP_DRIVER_CHECK=1   proceed anyway (the VM start will still fail)
check_driver:
	@VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" \
		$(SCRIPT_SH) setup/host/check_vbox_driver.sh

# =========@@ Whose VM is this? @@============================================
# disk_images/ is inside the shared home, so every workstation sees the same
# disk -- but only one of them is running the VM. install_vm_debian.sh stamps
# the owning machine into disk_images/<vm>/.built-on, and every destructive
# path (rm_disk_image, and therefore fclean / re / fresh) goes through this
# guard first, so a build started on the wrong machine cannot silently delete
# a VM that is in use on another one. Override deliberately with FORCE_HOST=1.
#
# Only a disk that actually holds an installed system (>100MB) is protected. A
# freshly created VDI is ~2MB and holds nothing, so a build that got as far as
# creating the disk and then failed does not leave a guard behind to trip over.
guard_host:
	@stamp="$(VM_PATH)/$(VM_NAME)/.built-on"; \
	vdi="$(VM_PATH)/$(VM_NAME)/$(VM_NAME).vdi"; \
	sz=0; [ -f "$$vdi" ] && sz=$$(stat -c %s "$$vdi" 2>/dev/null || echo 0); \
	if [ -r "$$stamp" ] && [ "$$sz" -gt 104857600 ]; then \
		owner=$$(head -n1 "$$stamp" | awk '{print $$1}'); \
		me=$$(hostname -f 2>/dev/null || hostname); \
		if [ -n "$$owner" ] && [ "$$owner" != "$$me" ] && [ "$(FORCE_HOST)" != "1" ]; then \
			printf "$(C_RED)✗$(C_RESET) Refusing to destroy VM \"$(VM_NAME)\" — it belongs to another machine.\n\n"; \
			printf "    built on : %s\n" "$$(head -n1 "$$stamp")"; \
			printf "    you are  : %s\n" "$$me"; \
			printf "    disk     : %s MB of installed system\n" "$$((sz / 1048576))"; \
			printf "\n  Your home is shared over NFS, so this is the SAME disk that machine\n"; \
			printf "  uses. Deleting it here would destroy a working VM over there.\n\n"; \
			printf "  Deliberately override by adding $(C_BOLD)FORCE_HOST=1$(C_RESET) to your command,\n"; \
			printf "  e.g.  $(C_BOLD)make re FORCE_HOST=1$(C_RESET)\n\n"; \
			exit 1; \
		fi; \
	fi

# =========@@ Fix incompatible HWE kernel (VirtualBox DKMS) @@=================
fix_hwe:
	@$(SCRIPT_SH) fixes/fix_hwe_kernel.sh

fix_app_ports:
	@$(SCRIPT_SH) fixes/fix_app_nat_forwarding.sh "$(VM_NAME)"


# =========@@ Build preseeded ISO @@============================================
gen_iso: shell
	@FORCE_ISO="$(FORCE_ISO)" CUSTOM_SHELL_PATH="$(CUSTOM_SHELL_PATH)" \
		AI_MODE="$(AI_MODE)" LUKS="$(LUKS)" $(SCRIPT_SH) $(ISO_BUILDER)

# =========@@ Create the VM @@==================================================
setup_vm:
	@VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" \
		DISK_SIZE_MB="$(DISK_SIZE_MB)" VM_RAM_MB="$(VM_RAM_MB)" \
		$(SCRIPT_SH) $(VM_SCRIPT) "$(VM_NAME)"

# =========@@ Start an existing VM @@===========================================
start_vm: check_system
	@if ! VBoxManage showvminfo "$(VM_NAME)" >/dev/null 2>&1; then \
		printf "$(C_RED)✗$(C_RESET) VM \"$(VM_NAME)\" does not exist. Run: make setup_vm\n"; \
		exit 1; \
	fi
	@VM_NAME="$(VM_NAME)" $(SCRIPT_SH) unlock_vm.sh

# Escape hatch: opens the VirtualBox window. Use when you need the console --
# to watch the installer, or to type the passphrase by hand.
gui_vm: check_system
	@if ! VBoxManage showvminfo "$(VM_NAME)" >/dev/null 2>&1; then \
		printf "$(C_RED)✗$(C_RESET) VM \"$(VM_NAME)\" does not exist. Run: make setup_vm\n"; \
		exit 1; \
	fi; \
	VM_STATE=$$(VBoxManage showvminfo "$(VM_NAME)" --machinereadable 2>/dev/null | grep "^VMState=" | cut -d\" -f2); \
	if [ "$$VM_STATE" = "running" ]; then \
		printf "$(C_GREEN)✓$(C_RESET) VM is already running\n"; \
	else \
		VBoxManage startvm "$(VM_NAME)" --type gui; \
	fi

# =========@@ Status @@========================================================
status:
	@$(SCRIPT_SH) generate/status.sh "$(VM_NAME)" "$(PRESEED_FILE)"

# =========@@ Serial console @@================================================
# The whole pipeline is headless, so nothing ever renders the VM's screen. The
# VM's COM1 is wired to a file instead (see setup/install/vms/install_vm_debian.sh)
# and the guest is booted with console=ttyS0, so that file is the VM's console
# as plain text: the installer's progress during `make all`, the kernel's boot
# messages afterwards.
#
#   make console      follow it live (Ctrl+C stops watching, not the VM)
#   make serial_log   print what is in it and exit
console:
	@$(SCRIPT_SH) generate/serial_console.sh "$(VM_NAME)" follow

serial_log:
	@$(SCRIPT_SH) generate/serial_console.sh "$(VM_NAME)" dump

# =========@@ Headless boot with unlock @@======================================
# start_vm is headless already; kept so existing habits and docs keep working.
bstart_vm: start_vm

# =========@@ Power off @@=====================================================
poweroff:
	@VBoxManage controlvm $(VM_NAME) acpipowerbutton 2>/dev/null || \
	 VBoxManage controlvm $(VM_NAME) poweroff 2>/dev/null || \
	 printf "$(C_YELLOW)VM is not running$(C_RESET)\n"

# =========@@ Listing / archive helpers @@=====================================
list_vms:
	@VBoxManage list vms 2>/dev/null || echo "No VMs found"

list_vms_iso:
	@tar -tf $(VMS_ISO_TAR) 2>/dev/null || echo "No ISO archive found"

extract_isos:
	@tar -xvf $(VMS_ISO_TAR)

push_iso:
	@tar -rf $(VMS_ISO_TAR) $(NEW_ISO)

pop_iso:
	@tar --exclude=$(NEW_ISO) -cf tmp_$(VMS_ISO_TAR) $(VMS_ISO_TAR) && \
	 mv tmp_$(VMS_ISO_TAR) $(VMS_ISO_TAR)

# =========@@ Destroy helpers @@===============================================
rm_disk_image: guard_host
	@if VBoxManage showvminfo "$(VM_NAME)" >/dev/null 2>&1; then \
		state=$$(VBoxManage showvminfo "$(VM_NAME)" --machinereadable 2>/dev/null \
			| grep '^VMState=' | cut -d'"' -f2); \
		if [ "$$state" = "running" ] || [ "$$state" = "paused" ] || [ "$$state" = "stuck" ]; then \
			printf "$(C_YELLOW)▶$(C_RESET) Powering off VM \"$(VM_NAME)\"...\n"; \
			VBoxManage controlvm "$(VM_NAME)" poweroff 2>/dev/null || true; \
			sleep 3; \
			i=0; while [ $$i -lt 10 ]; do \
				if VBoxManage modifyvm "$(VM_NAME)" --description "" >/dev/null 2>&1; then break; fi; \
				sleep 1; i=$$((i+1)); \
			done; \
		fi; \
		if VBoxManage unregistervm "$(VM_NAME)" --delete >/dev/null 2>&1; then \
			printf "$(C_GREEN)✓$(C_RESET) VM \"$(VM_NAME)\" removed\n"; \
		else \
			printf "$(C_RED)✗$(C_RESET) Failed to unregister VM — forcing cleanup\n"; \
			VBoxManage unregistervm "$(VM_NAME)" 2>/dev/null || true; \
			rm -rf "$(VM_PATH)/$(VM_NAME)" 2>/dev/null || true; \
			printf "$(C_GREEN)✓$(C_RESET) VM \"$(VM_NAME)\" force-removed\n"; \
		fi; \
	else \
		echo "VM '$(VM_NAME)' does not exist."; \
	fi


prune_vms:
	@for vm in $$(VBoxManage list vms 2>/dev/null | awk '{print $$1}' | tr -d '"'); do \
		VBoxManage unregistervm "$$vm" --delete >/dev/null 2>&1; \
	done; \
	printf "$(C_GREEN)✓$(C_RESET) All VMs removed\n"

clean:
	@chmod -R u+w debian_iso_extract 2>/dev/null || true
	$(RM) debian-*-amd64-netinst.iso debian-*-amd64-*preseed*.iso debian_iso_extract

# =========@@ Space @@=========================================================
# What this project costs, and whether that is still allowed. Fails (exit 1)
# when the total exceeds SPACE_BUDGET_GB rather than warning about it -- a
# warning mid-build scrolls past unread, and the point is to stop before
# writing the thing that blows the quota. See utils/space_budget.sh.
space:
	@SPACE_BUDGET_GB="$(SPACE_BUDGET_GB)" VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" \
		$(SCRIPT_SH) utils/space_budget.sh

# Hand back what is no longer used: the ISOs once the VM is installed, the
# guest's apt cache and orphaned packages, and the blocks the guest has freed
# but never trimmed. `make slim COMPACT=1` also rewrites the image without its
# unreferenced clusters, which needs the VM stopped.
slim:
	@SPACE_BUDGET_GB="$(SPACE_BUDGET_GB)" VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" \
		SCRIPT_SH="$(SCRIPT_SH)" \
		$(SCRIPT_SH) utils/slim.sh $(if $(filter 1,$(COMPACT)),--compact,)

# Empty VM_PATH, but do NOT delete the directory itself. When VM_PATH points at
# an external disk (VM_PATH=/mnt/storage/virtualbox) its parent is root-owned,
# so removing the directory leaves a path only root can recreate -- and the next
# `make all` dies on "mkdir: cannot create directory: Permission denied" with
# nothing saying that a previous fclean is what caused it.
fclean: clean rm_disk_image
	@[ -n "$(VM_PATH)" ] && [ -d "$(VM_PATH)" ] \
		&& rm -rf -- "$(VM_PATH)"/* "$(VM_PATH)"/.[!.]* 2>/dev/null; true

re: fclean all

# =========@@ One command, from nothing to a working site @@===================
# Destroys the VM, reinstalls Debian from the preseed, clones Inception into it,
# builds the stack, wires this host up and verifies the whole chain.
# $(MAKE) is deliberately not spelled out here — see the MAKE_BIN note above.
fresh:
	@$(MAKE_BIN) rm_disk_image
	@$(MAKE_BIN) all
	@$(MAKE_BIN) inception

# =========@@ Inception: host access to $(DOMAIN) @@===========================
# The subject requires the site to answer on $(DOMAIN). That name resolves only
# where something is told to resolve it: inside the VM that is the guest's own
# /etc/hosts, and on a 42 campus machine there is no root to add a host-side
# entry. host_access teaches the two installed browsers to resolve it
# themselves — no proxy, no SSH tunnel, no root. See the script's header.
host_access:
	@VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" INCEPTION_DOMAIN="$(DOMAIN)" $(SCRIPT_SH) setup/host/inception_host_access.sh

host_access_undo:
	@VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" INCEPTION_DOMAIN="$(DOMAIN)" $(SCRIPT_SH) setup/host/inception_host_access.sh --undo

# Clone (or upload) Inception into the VM, build it, wire up the host, verify.
#   make inception                    clone github.com/Univers42/inception
#   make inception SRC=/path/to/repo  push a local working tree up instead
inception:
	@VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" INCEPTION_DOMAIN="$(DOMAIN)" INCEPTION_SRC="$(SRC)" \
		$(SCRIPT_SH) setup/host/deploy_inception.sh

# Prove it from the host: NAT rules, TLS/SNI, the WordPress redirect trap, and
# a real headless browser load of the bare https://$(DOMAIN) URL.
verify_access:
	@VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" INCEPTION_DOMAIN="$(DOMAIN)" $(SCRIPT_SH) setup/host/verify_inception_access.sh

# Common misspelling. `make` has no "did you mean", so a typo here fails with a
# bare "No rule to make target" right after host_access printed all-green --
# which reads as the setup having broken, when nothing has. Same reasoning as
# the bstart_vm alias above.
verif_access: verify_access

# =========@@ Editor + shell provisioning @@===================================
# `make all` already bakes both of these into the ISO and runs them at first
# boot. These targets are the other half: applying them over SSH to a VM that
# is ALREADY built, so the scripts can be iterated on without a 20-minute
# rebuild, and so a machine that predates them can catch up.
#
#   make nvim                      Neovim (latest upstream) + kickstart.nvim
#   make nvim NVIM_VERSION=latest  ...tracking the newest release
#   make hellish_plugins           the hellishrc plugin framework
#   make provision                 both, then print the health report
#   make nvim_health               just re-print :checkhealth from the VM
nvim:
	@VM_PATH="$(VM_PATH)" NVIM_VERSION="$(NVIM_VERSION)" NVIM_USERS="$(NVIM_USERS)" \
		$(SCRIPT_SH) setup/host/provision_vm.sh "$(VM_NAME)" nvim

hellish_plugins:
	@VM_PATH="$(VM_PATH)" $(SCRIPT_SH) setup/host/provision_vm.sh "$(VM_NAME)" hellish

# Re-run upstream's hellish installer inside a VM that is already built:
#   curl -fsSL .../hellish/main/install.sh | sh
# driven with --yes, so every question takes its default instead of needing
# answers piped in. Installs the current release + the plugin framework, then
# re-links /usr/bin/hellish to the fresh hellish.real and pins it as the
# interpreter of what the guest runs itself (cron, the two units, first
# boot's provisioners) -- which also converts a guest built with the old bash
# wrapper. `make all` already does this on first boot; this is for iterating
# without a rebuild.
shell_vm:
	@VM_PATH="$(VM_PATH)" $(SCRIPT_SH) setup/host/provision_vm.sh "$(VM_NAME)" shell

provision:
	@VM_PATH="$(VM_PATH)" NVIM_VERSION="$(NVIM_VERSION)" NVIM_USERS="$(NVIM_USERS)" \
		$(SCRIPT_SH) setup/host/provision_vm.sh "$(VM_NAME)" all

nvim_health:
	@VM_PATH="$(VM_PATH)" $(SCRIPT_SH) setup/host/provision_vm.sh "$(VM_NAME)" health

# Machine-wide tooling on /opt instead of / and /home (npm globals, AI models).
global_scope:
	@VM_PATH="$(VM_PATH)" $(SCRIPT_SH) setup/host/provision_vm.sh "$(VM_NAME)" global

# Herdr (persistent terminal panes over SSH) + Claude Code.
devtools:
	@VM_PATH="$(VM_PATH)" $(SCRIPT_SH) setup/host/provision_vm.sh "$(VM_NAME)" devtools

# Optional AI. Does nothing unless AI_MODE is client or local:
#   make ai AI_MODE=local        a model sized to this VM's RAM
#   make ai AI_MODE=client       talk to Ollama on the host (10.0.2.2)
ai:
	@VM_PATH="$(VM_PATH)" AI_MODE="$(AI_MODE)" $(SCRIPT_SH) setup/host/provision_vm.sh "$(VM_NAME)" ai

# =========@@ Help @@==========================================================
help:
	@$(SCRIPT_SH) generate/help.sh
