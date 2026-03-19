# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: Invalid date        by ut down the       #+#    #+#              #
#    Updated: 2026/03/16 17:51:20 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# ============================================================================ #

# =========@@ Config @@=========================================================
VM_NAME      ?= debian
VM_SCRIPT    := ./setup/install/vms/install_vm_debian.sh
ISO_BUILDER  := ./generate/create_custom_iso.sh
PRESEED_FILE := preseeds/preseed.cfg
DISK_DIR     := disk_images
RM           := rm -rf
VMS_ISO_TAR  := vms_iso.tar

# Force rebuilding the preseed ISO even if it already exists.
# `make all` sets this automatically so the ISO always matches the latest scripts/binaries.
FORCE_ISO ?= 0

# Optional: set a custom default login shell inside the VM.
# Default is hellish from the sh42 submodule build.
# To keep bash, override with an empty value:
#   make gen_iso CUSTOM_SHELL_PATH=
CUSTOM_SHELL_PATH ?= sh42/build/bin/hellish
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
.PHONY: all prepare pull shell deps check_system fix_hwe gen_iso setup_vm start_vm status help \
        clean fclean re poweroff list_vms prune_vms \
        list_vms_iso extract_isos push_iso pop_iso rm_disk_image bstart_vm

all: prepare
	@CUSTOM_SHELL_PATH="$(CUSTOM_SHELL_PATH)" FORCE_ISO=1 bash generate/orchestrate.sh "$(VM_NAME)" "$(MAKE)"

# Prepare everything needed for a smooth `make all` experience:
# - update repo (if this is a git checkout)
# - init/sync/update submodules
# - build the sh42 hellish shell with parallel jobs
prepare: pull update shell

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
		git stash pop -q 2>/dev/null || true; \
	fi'

update:
	@git submodule update --init --recursive --remote


# Build the custom shell from sh42 (parallel)
shell:
	@if [ ! -f sh42/Makefile ]; then \
		printf "$(C_RED)✗$(C_RESET) sh42 submodule is missing. Run: git submodule update --init --recursive\n"; \
		exit 1; \
	fi
	@printf "$(C_BLUE)▶$(C_RESET) Building sh42 (hellish)...\n"
	@$(MAKE) -C sh42 OPT=1
	@if [ -f sh42/build/bin/hellish ]; then \
		printf "$(C_GREEN)✓$(C_RESET) hellish built: sh42/build/bin/hellish\n"; \
	else \
		printf "$(C_RED)✗$(C_RESET) hellish binary missing after build\n"; \
		exit 1; \
	fi

# =========@@ Install VirtualBox (cross-distro) @@=============================
deps:
	@bash -c '\
	set -e; \
	if command -v VBoxManage >/dev/null 2>&1; then \
		printf "$(C_GREEN)✓$(C_RESET) VirtualBox already installed\n"; \
		exit 0; \
	fi; \
	printf "$(C_YELLOW)Installing VirtualBox...$(C_RESET)\n"; \
	if command -v apt-get >/dev/null 2>&1; then \
		sudo apt-get update -qq && sudo apt-get install -y virtualbox; \
	elif command -v dnf >/dev/null 2>&1; then \
		sudo dnf install -y VirtualBox; \
	elif command -v yum >/dev/null 2>&1; then \
		sudo yum install -y VirtualBox; \
	elif command -v pacman >/dev/null 2>&1; then \
		sudo pacman -Sy --noconfirm virtualbox virtualbox-host-modules-arch; \
	elif command -v zypper >/dev/null 2>&1; then \
		sudo zypper install -y virtualbox; \
	elif command -v brew >/dev/null 2>&1; then \
		brew install --cask virtualbox; \
	else \
		printf "$(C_RED)✗ Cannot detect package manager. Install VirtualBox manually.$(C_RESET)\n"; \
		exit 1; \
	fi; \
	for tool in xorriso curl; do \
		if ! command -v $$tool >/dev/null 2>&1; then \
			printf "$(C_YELLOW)Installing $$tool...$(C_RESET)\n"; \
			if   command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y $$tool; \
			elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y $$tool; \
			elif command -v pacman  >/dev/null 2>&1; then sudo pacman -Sy --noconfirm $$tool; \
			elif command -v zypper  >/dev/null 2>&1; then sudo zypper install -y $$tool; \
			elif command -v brew    >/dev/null 2>&1; then brew install $$tool; \
			fi; \
		fi; \
	done; \
	printf "$(C_GREEN)✓$(C_RESET) Dependencies installed\n"'

# =========@@ System compatibility pre-checks @@==============================
check_system:
	@bash -c '\
	ERRORS=0; \
	KERN=$$(uname -r); \
	printf "$(C_BLUE)▶$(C_RESET) Pre-flight checks (running kernel: $$KERN)\n"; \
	HWE_PKGS=$$(dpkg -l 2>/dev/null \
		| awk "/^ii.*linux-image-[0-9]/{print \$$2}" \
		| grep -E "linux-image-6\.(1[3-9]|[2-9][0-9])\.|linux-image-[7-9]\." \
		| tr "\n" " "); \
	if [ -n "$$HWE_PKGS" ]; then \
		printf "$(C_YELLOW)⚠$(C_RESET)  Incompatible HWE kernel(s) installed: $$HWE_PKGS\n"; \
		printf "$(C_YELLOW)  VirtualBox 7.0.x DKMS cannot build against these kernels and\n$(C_RESET)"; \
		printf "$(C_YELLOW)  may break entirely even when booting an older kernel.\n$(C_RESET)"; \
		printf "$(C_YELLOW)  Fix:$(C_RESET) make fix_hwe\n"; \
	fi; \
	if ! test -c /dev/vboxdrv 2>/dev/null; then \
		printf "$(C_RED)✗$(C_RESET) /dev/vboxdrv missing — VirtualBox kernel driver not loaded\n"; \
		ERRORS=$$((ERRORS+1)); \
		if command -v dkms >/dev/null 2>&1; then \
			DKMS_BAD=$$(dkms status 2>/dev/null | grep -i vbox | grep -iv installed | head -5); \
			if [ -n "$$DKMS_BAD" ]; then \
				printf "$(C_RED)  Broken DKMS entries:$(C_RESET) $$DKMS_BAD\n"; \
				printf "$(C_YELLOW)  Fix:$(C_RESET) sudo dpkg --configure -a && sudo modprobe vboxdrv\n"; \
			else \
				printf "$(C_YELLOW)  Run:$(C_RESET) sudo modprobe vboxdrv\n"; \
			fi; \
		else \
			printf "$(C_YELLOW)  Run:$(C_RESET) sudo modprobe vboxdrv\n"; \
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

# =========@@ Fix incompatible HWE kernel (VirtualBox DKMS) @@=================
fix_hwe:
	@bash fixes/fix_hwe_kernel.sh


# =========@@ Build preseeded ISO @@============================================
gen_iso: shell
	@FORCE_ISO="$(FORCE_ISO)" CUSTOM_SHELL_PATH="$(CUSTOM_SHELL_PATH)" bash $(ISO_BUILDER)

# =========@@ Create the VM @@==================================================
setup_vm:
	@bash $(VM_SCRIPT)

# =========@@ Start an existing VM @@===========================================
start_vm: check_system
	@bash -c '\
	if ! VBoxManage showvminfo "$(VM_NAME)" >/dev/null 2>&1; then \
		printf "$(C_RED)✗$(C_RESET) VM \"$(VM_NAME)\" does not exist. Run: make setup_vm\n"; \
		exit 1; \
	fi; \
	VM_STATE=$$(VBoxManage showvminfo "$(VM_NAME)" --machinereadable 2>/dev/null | grep "^VMState=" | cut -d\" -f2); \
	if [ "$$VM_STATE" = "running" ]; then \
		printf "$(C_GREEN)✓$(C_RESET) VM is already running\n"; \
	else \
		VBoxManage startvm "$(VM_NAME)" --type gui; \
	fi'

# =========@@ Status @@========================================================
status:
	@bash generate/status.sh "$(VM_NAME)" "$(PRESEED_FILE)"

# =========@@ Headless boot with unlock @@======================================
bstart_vm: check_system
	@bash -c '\
	if ! VBoxManage showvminfo "$(VM_NAME)" >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory setup_vm; \
	fi; \
	bash unlock_vm.sh > vm_boot.log 2>&1 & \
	printf "Waiting for VM to boot (see vm_boot.log)...\n"; \
	for i in $$(seq 1 30); do \
		if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -p 4242 dlesieur@127.0.0.1 exit 2>/dev/null; then \
			printf "$(C_GREEN)✓ VM is ready!$(C_RESET)\n"; \
			exit 0; \
		fi; \
		printf "."; \
		sleep 2; \
	done; \
	printf "\n$(C_YELLOW)⚠ SSH not responding yet — VM may still be booting$(C_RESET)\n"'

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
rm_disk_image:
	@if VBoxManage showvminfo "$(VM_NAME)" >/dev/null 2>&1; then \
		state=$$(VBoxManage showvminfo "$(VM_NAME)" --machinereadable 2>/dev/null \
		        | grep '^VMState=' | cut -d'"' -f2); \
		if [ "$$state" = "running" ] || [ "$$state" = "paused" ] || [ "$$state" = "stuck" ]; then \
			printf "$(C_YELLOW)▶$(C_RESET) Powering off VM \"$(VM_NAME)\"...\n"; \
			VBoxManage controlvm "$(VM_NAME)" poweroff 2>/dev/null || true; \
			sleep 3; \
			i=0; while [ $$i -lt 10 ]; do \
				if VBoxManage modifyvm "$(VM_NAME)" --description "" 2>/dev/null; then break; fi; \
				sleep 1; i=$$((i+1)); \
			done; \
		fi; \
		if VBoxManage unregistervm "$(VM_NAME)" --delete 2>/dev/null; then \
			printf "$(C_GREEN)✓$(C_RESET) VM \"$(VM_NAME)\" removed\n"; \
		else \
			printf "$(C_RED)✗$(C_RESET) Failed to unregister VM — forcing cleanup\n"; \
			VBoxManage unregistervm "$(VM_NAME)" 2>/dev/null || true; \
			rm -rf "$(DISK_DIR)/$(VM_NAME)" 2>/dev/null || true; \
			printf "$(C_GREEN)✓$(C_RESET) VM \"$(VM_NAME)\" force-removed\n"; \
		fi; \
	else \
		echo "VM '$(VM_NAME)' does not exist."; \
	fi

prune_vms:
	@for vm in $$(VBoxManage list vms 2>/dev/null | awk '{print $$1}' | tr -d '"'); do \
		VBoxManage unregistervm "$$vm" --delete 2>/dev/null; \
	done; \
	printf "$(C_GREEN)✓$(C_RESET) All VMs removed\n"

clean:
	@chmod -R u+w debian_iso_extract 2>/dev/null || true
	$(RM) debian-*-amd64-netinst.iso debian-*-amd64-*preseed.iso debian_iso_extract

fclean: clean rm_disk_image
	$(RM) $(DISK_DIR)

re: fclean all

# =========@@ Help @@==========================================================
help:
	@bash generate/help.sh
