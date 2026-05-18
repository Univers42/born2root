# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: Invalid date        by ut down the       #+#    #+#              #
#    Updated: 2026/05/14 16:02:51 by dlesieur         ###   ########.fr        #
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
.PHONY: all prepare pull shell deps check_system fix_hwe fix_app_ports gen_iso setup_vm start_vm status help \
        clean fclean re poweroff list_vms prune_vms \
        list_vms_iso extract_isos push_iso pop_iso rm_disk_image bstart_vm

all: prepare
	@CUSTOM_SHELL_PATH="$(CUSTOM_SHELL_PATH)" FORCE_ISO=1 bash generate/orchestrate.sh "$(VM_NAME)" "$(MAKE)"

# Prepare everything needed for a smooth `make all` experience:
# - check + install host dependencies (VirtualBox, xorriso, gcc, libreadline-dev, …)
# - update repo (if this is a git checkout)
# - init/sync/update submodules
# - build the sh42 hellish shell with parallel jobs
prepare: deps pull update shell

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

LIBFT_LAST_GOOD := 685e57d8

update:
	@git submodule update --init --recursive
	@if [ -f sh42/vendor/libft/.git ] || [ -d sh42/vendor/libft/.git ]; then \
		count=$$(git -C sh42/vendor/libft ls-tree -r HEAD --name-only 2>/dev/null | grep "\.c$$" | wc -l); \
		if [ "$$count" -lt 10 ]; then \
			printf "$(C_YELLOW)⚠$(C_RESET)  sh42/vendor/libft upstream wiped sources — restoring last good commit ($(LIBFT_LAST_GOOD))\n"; \
			git -C sh42/vendor/libft checkout $(LIBFT_LAST_GOOD) -- . 2>/dev/null && \
				printf "$(C_GREEN)✓$(C_RESET) vendor/libft sources restored\n" || \
				printf "$(C_RED)✗$(C_RESET) could not restore vendor/libft — build may fail\n"; \
		fi; \
	fi


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

# =========@@ Install host developer dependencies @@==========================
# Checks for: VirtualBox + ext-pack, xorriso, curl, gcc, libreadline-dev,
# python3, git, openssh-client, make.
# Missing packages are installed via `sudo apt install` WITHOUT -y so the
# user reviews and confirms the apt plan themselves.
deps:
	@bash setup/install/check_deps.sh

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

# =========@@ Fix incompatible HWE kernel (VirtualBox DKMS) @@=================
fix_hwe:
	@bash fixes/fix_hwe_kernel.sh

fix_app_ports:
	@bash fixes/fix_app_nat_forwarding.sh "$(VM_NAME)"


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
	SSH_PORT=$$(VBoxManage showvminfo "$(VM_NAME)" --machinereadable 2>/dev/null | grep "^Forwarding" | grep "\"ssh,tcp," | head -1 | cut -d, -f4); \
	if [ -z "$$SSH_PORT" ]; then SSH_PORT=4242; fi; \
	bash unlock_vm.sh > vm_boot.log 2>&1 & \
	printf "Waiting for VM to boot (see vm_boot.log)...\n"; \
	for i in $$(seq 1 30); do \
		if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -p "$$SSH_PORT" dlesieur@127.0.0.1 exit 2>/dev/null; then \
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
