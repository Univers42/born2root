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
VM_PATH	     ?= $(CURDIR)/disk_images
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

# Disk size for a NEW VM, in MB. The VDI is dynamically allocated, so this is a
# ceiling and not an allocation — an untouched 120GB disk is ~2MB on the host.
# The partition recipe pins every volume and leaves ~12GB unallocated in the
# volume group, so raising this grows that free pool; give it to a specific
# filesystem afterwards with lvextend + resize2fs.
# Only affects a VM being created: an existing disk is kept.
DISK_SIZE_MB ?= 122880

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
        qemu_install qemu_start qemu_stop qemu_status qemu_console verify_guest

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

all: prepare
	@backend=$$(BACKEND="$(BACKEND)" bash setup/host/select_backend.sh "$(BACKEND)") || exit 1; \
	if [ "$$backend" = "qemu" ]; then \
		CUSTOM_SHELL_PATH="$(CUSTOM_SHELL_PATH)" FORCE_ISO=1 AI_MODE="$(AI_MODE)" \
		DISK_SIZE_MB="$(DISK_SIZE_MB)" VM_RAM_MB="$(VM_RAM_MB)" VM_NAME="$(VM_NAME)" \
		VM_PATH="$(VM_PATH)" MAKE_BIN="$(MAKE_BIN)" \
			bash setup/host/qemu_pipeline.sh; \
	else \
		$(MAKE_BIN) --no-print-directory check_driver && \
		CUSTOM_SHELL_PATH="$(CUSTOM_SHELL_PATH)" FORCE_ISO=1 AI_MODE="$(AI_MODE)" \
		DISK_SIZE_MB="$(DISK_SIZE_MB)" VM_RAM_MB="$(VM_RAM_MB)" \
			bash generate/orchestrate.sh "$(VM_NAME)" "$(MAKE_BIN)"; \
	fi
	@VM_NAME="$(VM_NAME)" INCEPTION_DOMAIN="$(DOMAIN)" bash setup/host/inception_host_access.sh

# Which backend would `make all` pick right now, and why?
backend:
	@BACKEND="$(BACKEND)" bash setup/host/select_backend.sh "$(BACKEND)" >/dev/null

# =========@@ QEMU/KVM backend @@=============================================
# The same VM, run by QEMU instead of VirtualBox. Useful on its own when you
# want to drive the phases by hand rather than through `make all`.
QEMU_ENV = VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" \
	DISK_SIZE_MB="$(DISK_SIZE_MB)" VM_RAM_MB="$(VM_RAM_MB)"

qemu_install:
	@$(QEMU_ENV) bash setup/host/qemu_vm.sh create
	@$(QEMU_ENV) bash setup/host/qemu_vm.sh install

qemu_start:
	@$(QEMU_ENV) bash setup/host/qemu_vm.sh start
	@$(QEMU_ENV) bash setup/host/qemu_vm.sh ssh-config

qemu_stop:
	@$(QEMU_ENV) bash setup/host/qemu_vm.sh stop

qemu_status:
	@$(QEMU_ENV) bash setup/host/qemu_vm.sh status

qemu_console:
	@$(QEMU_ENV) bash setup/host/qemu_vm.sh console

# Prove the guest is the same whichever backend built it: partitions, LUKS,
# LVM, UFW, the policy files and the login shell all come from the preseeded
# ISO. Run it on both and diff the output.
verify_guest:
	@BACKEND_LABEL="$(BACKEND)" bash setup/host/verify_guest_parity.sh

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

# NOTE on the stash dance: `git stash pop` WITHOUT --index restores your work
# to the working tree but throws the index away, silently un-staging everything
# you had staged before running make. --index puts the staged/unstaged split
# back; the bare pop is kept only as a fallback for the case where --index
# cannot reapply cleanly.
pull:
	@bash -c '\
	if [ -d .git ]; then \
		printf "$(C_BLUE)▶$(C_RESET) Pulling latest from origin/main...\n"; \
		git stash -q 2>/dev/null || true; \
		if git pull --ff-only origin main 2>/dev/null; then \
			printf "$(C_GREEN)✓$(C_RESET) Repository up to date\n"; \
		else \
			printf "$(C_YELLOW)⚠$(C_RESET)  Fast-forward failed — merging...\n"; \
			git pull origin main 2>/dev/null || \
				printf "$(C_YELLOW)⚠$(C_RESET)  git pull failed (working offline?)\n"; \
		fi; \
		git stash pop --index -q 2>/dev/null \
			|| git stash pop -q 2>/dev/null || true; \
	fi'

# Sync + update ALL submodules (any depth) to the latest upstream commit, and repair
# orphan gitlinks (submodule paths an upstream repo committed without a .gitmodules
# entry, e.g. libft's srcs/memory/ft_malloc). Fully auto-detected — see the script.
#
# NOTE: no longer part of `prepare`, and this repo now registers NO submodules
# (sh42 was removed in favour of the downloaded hellish release). Kept as
# generic machinery in case one is ever added back; it is a no-op today.
update:
	@bash setup/update_submodules.sh


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
		OUT_BIN="$(CUSTOM_SHELL_PATH)" bash setup/fetch_hellish.sh


# =========@@ Install host developer dependencies @@==========================
# Checks for: VirtualBox + ext-pack, xorriso, curl, gcc, libreadline-dev,
# python3, git, openssh-client, make.
# Missing packages are installed via `sudo apt install` WITHOUT -y so the
# user reviews and confirms the apt plan themselves.
deps:
	@bash setup/install/check_deps.sh

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
	@INSTALL_EXTPACK=1 bash setup/install/check_deps.sh

# =========@@ System compatibility pre-checks @@==============================
check_system:
	@bash -c '\
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
		bash setup/host/check_vbox_driver.sh

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
	@bash fixes/fix_hwe_kernel.sh

fix_app_ports:
	@bash fixes/fix_app_nat_forwarding.sh "$(VM_NAME)"


# =========@@ Build preseeded ISO @@============================================
gen_iso: shell
	@FORCE_ISO="$(FORCE_ISO)" CUSTOM_SHELL_PATH="$(CUSTOM_SHELL_PATH)" \
		AI_MODE="$(AI_MODE)" bash $(ISO_BUILDER)

# =========@@ Create the VM @@==================================================
setup_vm:
	@VM_NAME="$(VM_NAME)" VM_PATH="$(VM_PATH)" \
		DISK_SIZE_MB="$(DISK_SIZE_MB)" VM_RAM_MB="$(VM_RAM_MB)" \
		bash $(VM_SCRIPT) "$(VM_NAME)"

# =========@@ Start an existing VM @@===========================================
start_vm: check_system
	@if ! VBoxManage showvminfo "$(VM_NAME)" >/dev/null 2>&1; then \
		printf "$(C_RED)✗$(C_RESET) VM \"$(VM_NAME)\" does not exist. Run: make setup_vm\n"; \
		exit 1; \
	fi
	@VM_NAME="$(VM_NAME)" bash unlock_vm.sh

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
	@bash generate/status.sh "$(VM_NAME)" "$(PRESEED_FILE)"

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
	@bash generate/serial_console.sh "$(VM_NAME)" follow

serial_log:
	@bash generate/serial_console.sh "$(VM_NAME)" dump

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
	$(RM) debian-*-amd64-netinst.iso debian-*-amd64-*preseed.iso debian_iso_extract

fclean: clean rm_disk_image
	$(RM) $(VM_PATH)
	$(RM) "$(VM_PATH)/$(VM_NAME)"

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
	@VM_NAME="$(VM_NAME)" INCEPTION_DOMAIN="$(DOMAIN)" bash setup/host/inception_host_access.sh

host_access_undo:
	@VM_NAME="$(VM_NAME)" INCEPTION_DOMAIN="$(DOMAIN)" bash setup/host/inception_host_access.sh --undo

# Clone (or upload) Inception into the VM, build it, wire up the host, verify.
#   make inception                    clone github.com/Univers42/inception
#   make inception SRC=/path/to/repo  push a local working tree up instead
inception:
	@VM_NAME="$(VM_NAME)" INCEPTION_DOMAIN="$(DOMAIN)" INCEPTION_SRC="$(SRC)" \
		bash setup/host/deploy_inception.sh

# Prove it from the host: NAT rules, TLS/SNI, the WordPress redirect trap, and
# a real headless browser load of the bare https://$(DOMAIN) URL.
verify_access:
	@VM_NAME="$(VM_NAME)" INCEPTION_DOMAIN="$(DOMAIN)" bash setup/host/verify_inception_access.sh

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
	@NVIM_VERSION="$(NVIM_VERSION)" NVIM_USERS="$(NVIM_USERS)" \
		bash setup/host/provision_vm.sh "$(VM_NAME)" nvim

hellish_plugins:
	@bash setup/host/provision_vm.sh "$(VM_NAME)" hellish

# Re-run upstream's hellish installer inside a VM that is already built:
#   curl -fsSL .../hellish/main/install.sh | sh
# driven with --yes, so every question takes its default instead of needing
# answers piped in. Installs the current release + the plugin framework, then
# re-applies the SSH-compatibility wrapper. `make all` already does this on
# first boot; this is for iterating without a rebuild.
shell_vm:
	@bash setup/host/provision_vm.sh "$(VM_NAME)" shell

provision:
	@NVIM_VERSION="$(NVIM_VERSION)" NVIM_USERS="$(NVIM_USERS)" \
		bash setup/host/provision_vm.sh "$(VM_NAME)" all

nvim_health:
	@bash setup/host/provision_vm.sh "$(VM_NAME)" health

# Machine-wide tooling on /opt instead of / and /home (npm globals, AI models).
global_scope:
	@bash setup/host/provision_vm.sh "$(VM_NAME)" global

# Herdr (persistent terminal panes over SSH) + Claude Code.
devtools:
	@bash setup/host/provision_vm.sh "$(VM_NAME)" devtools

# Optional AI. Does nothing unless AI_MODE is client or local:
#   make ai AI_MODE=local        a model sized to this VM's RAM
#   make ai AI_MODE=client       talk to Ollama on the host (10.0.2.2)
ai:
	@AI_MODE="$(AI_MODE)" bash setup/host/provision_vm.sh "$(VM_NAME)" ai

# =========@@ Help @@==========================================================
help:
	@bash generate/help.sh
