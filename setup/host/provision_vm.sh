#!/usr/bin/env bash
#
# provision_vm.sh — run a provisioner script inside a running VM, over SSH.
#
# The two provisioners this exists for (Neovim + kickstart, and the hellishrc
# plugin framework) are already baked into the ISO and run at first boot. This
# is the other half: applying them to a VM that is ALREADY built, without a
# rebuild — for iterating on the scripts, for re-running after a failed first
# boot, or for adding them to a machine that predates them.
#
# The VM's SSH port is read back from VirtualBox's NAT rules rather than
# assumed to be 4242: when a second VM is built beside an existing one, the
# host-port allocator (utils/host_ports.sh) walks past ports already in use, so
# the second machine's ssh rule lands on 4243 or higher.
#
# USAGE
#   bash setup/host/provision_vm.sh <vm-name> nvim
#   bash setup/host/provision_vm.sh <vm-name> hellish
#   bash setup/host/provision_vm.sh <vm-name> shell     (hellish from upstream)
#   bash setup/host/provision_vm.sh <vm-name> health          # print checkhealth
#   bash setup/host/provision_vm.sh <vm-name> all
#
# Environment passed through to the guest script, e.g.
#   NVIM_VERSION=latest bash setup/host/provision_vm.sh debian-nvim nvim

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

VM_NAME="${1:-debian}"
ACTION="${2:-all}"
VM_USER="${VM_USER:-dlesieur}"
VM_PASS_FILE="${VM_PASS_FILE:-vm_pass.txt}"

C_R='\033[0m'; C_B='\033[1m'; C_GRN='\033[32m'; C_YEL='\033[33m'; C_RED='\033[31m'; C_BLU='\033[34m'
info() { printf "${C_BLU}▶${C_R} %s\n" "$*"; }
ok()   { printf "${C_GRN}✓${C_R} %s\n" "$*"; }
warn() { printf "${C_YEL}!${C_R} %s\n" "$*"; }
die()  { printf "${C_RED}✗${C_R} %s\n" "$*" >&2; exit 1; }

command -v VBoxManage >/dev/null 2>&1 || die "VBoxManage not found"

VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1 \
	|| die "VM \"$VM_NAME\" does not exist. Existing VMs: $(VBoxManage list vms | tr '\n' ' ')"

state=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null \
	| grep '^VMState=' | cut -d'"' -f2)
[ "$state" = "running" ] \
	|| die "VM \"$VM_NAME\" is $state, not running. Start it with: make start_vm VM_NAME=$VM_NAME"

# ── Where does this VM's SSH live on the host? ──────────────────────────────
SSH_PORT=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null \
	| awk -F'"' '$1 ~ /^Forwarding/ && $2 ~ /^ssh,tcp,/ { print $2; exit }' \
	| cut -d',' -f4)
[ -n "$SSH_PORT" ] || die "VM \"$VM_NAME\" has no NAT rule named 'ssh'"
info "VM \"$VM_NAME\" — ssh on 127.0.0.1:${SSH_PORT} as ${VM_USER}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=15
	-o ServerAliveCountMax=6 -p "$SSH_PORT")
# Born2beRoot's sudoers sets `Defaults requiretty`, which the subject mandates.
# Without a pty every sudo call fails with "you must have a tty to run sudo",
# so anything privileged has to be run through `ssh -tt`.
SSH_TTY_OPTS=(-tt "${SSH_OPTS[@]}")
SCP_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR -o ConnectTimeout=15 -P "$SSH_PORT")

# The build bakes the host's public key into the VM, so key auth is the normal
# path. sshpass is only a fallback for a VM built before that, or one whose key
# was rotated; it reads the same vm_pass.txt the rest of the project uses.
SSH_PREFIX=()
if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${VM_USER}@127.0.0.1" true 2>/dev/null; then
	if command -v sshpass >/dev/null 2>&1 && [ -f "$VM_PASS_FILE" ]; then
		warn "key auth failed — falling back to sshpass with $VM_PASS_FILE"
		SSH_PREFIX=(sshpass -f "$VM_PASS_FILE")
	else
		die "cannot reach ${VM_USER}@127.0.0.1:${SSH_PORT} with key auth (and sshpass/$VM_PASS_FILE unavailable)"
	fi
fi

vm_ssh()  { "${SSH_PREFIX[@]}" ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "$@"; }
# A pty turns every newline into CR-LF on the way back, which makes the output
# look double-spaced and breaks anything downstream that matches line ends.
vm_ssh_tty() { "${SSH_PREFIX[@]}" ssh "${SSH_TTY_OPTS[@]}" "${VM_USER}@127.0.0.1" "$@" | tr -d '\r'; }
vm_scp()  { "${SSH_PREFIX[@]}" scp "${SCP_OPTS[@]}" "$@"; }

# ── The sudo password ───────────────────────────────────────────────────────
# The VM's user password is set by the preseed, so the preseed is the source of
# truth for it. Note it is NOT the passphrase in vm_pass.txt: that one unlocks
# the LUKS volume and is a different secret.
resolve_sudo_pass() {
	if [ -n "${VM_SUDO_PASS:-}" ]; then
		printf '%s' "$VM_SUDO_PASS"
		return 0
	fi
	if [ -n "${VM_SUDO_PASS_FILE:-}" ] && [ -f "$VM_SUDO_PASS_FILE" ]; then
		head -n1 "$VM_SUDO_PASS_FILE" | tr -d '\r\n'
		return 0
	fi
	if [ -f preseeds/preseed.cfg ]; then
		awk '/^d-i passwd\/user-password[[:space:]]/ { print $4; exit }' preseeds/preseed.cfg
		return 0
	fi
	return 1
}

# Run a privileged command in the VM.
#
# Three ways sudo might be reachable, tried in order:
#   1. passwordless sudo (still needs the pty, because of requiretty);
#   2. SUDO_ASKPASS — a throwaway helper on the VM that echoes the password.
#      This is used in preference to `sudo -S` because with -tt the pty echoes
#      everything written to stdin, which would print the password into the
#      build log;
#   3. nothing works, so say so clearly rather than hanging on a prompt.
PASS_REMOTE="/tmp/.b2b-pw.$$"
ASKPASS_REMOTE="/tmp/.b2b-askpass.$$"
SUDO_CMD="sudo -n"
askpass_installed=0

cleanup_askpass() {
	[ "$askpass_installed" = "1" ] || return 0
	vm_ssh "rm -f '$ASKPASS_REMOTE' '$PASS_REMOTE'" >/dev/null 2>&1 || true
	askpass_installed=0
}
trap cleanup_askpass EXIT

setup_sudo() {
	if vm_ssh_tty "sudo -n true" >/dev/null 2>&1; then
		SUDO_CMD="sudo -n"
		info "sudo: passwordless"
		return 0
	fi

	local pass
	pass=$(resolve_sudo_pass) || true
	if [ -z "$pass" ]; then
		die "the VM asks for a sudo password and none could be found.
     Set one explicitly:  VM_SUDO_PASS=... make provision
     or point at a file:  VM_SUDO_PASS_FILE=/path/to/file make provision"
	fi

	# The password travels on stdin and lands in a mode-600 file; the askpass
	# helper is a two-line script that cats it. It is done this way rather than
	# with `sudo -S` because the pty that requiretty forces us to allocate echoes
	# everything written to its stdin -- a piped password would be printed
	# straight into the build log. Nothing here puts the secret on a command line
	# either, so it cannot be read out of the VM's process list while it runs.
	if ! printf '%s' "$pass" | vm_ssh "umask 077; cat > '$PASS_REMOTE'"; then
		die "could not upload the sudo password to the VM"
	fi
	askpass_installed=1
	if ! vm_ssh "umask 077; printf '#!/bin/sh\\ncat %s\\n' '$PASS_REMOTE' > '$ASKPASS_REMOTE'; chmod 700 '$ASKPASS_REMOTE'"; then
		die "could not install the sudo askpass helper in the VM"
	fi

	if ! vm_ssh_tty "SUDO_ASKPASS='$ASKPASS_REMOTE' sudo -A true" >/dev/null 2>&1; then
		die "the sudo password was rejected by the VM (set VM_SUDO_PASS to the right one)"
	fi
	SUDO_CMD="SUDO_ASKPASS='$ASKPASS_REMOTE' sudo -A"
	info "sudo: password accepted"
}

# Forward only the variables the guest scripts document, and quote them, so a
# value with a space cannot turn into extra shell words on the far side.
build_env() {
	# Accepts several space-separated prefixes, because a script's knobs do not
	# always share one: install_devtools.sh reads both HERDR_* and INSTALL_*.
	local prefixes="$1" prefix var out=""
	for prefix in $prefixes; do
	for var in $(compgen -v | grep "^${prefix}" || true); do
		# Skip empties: `make nvim` always passes NVIM_VERSION, blank when the
		# user did not override it, and forwarding NVIM_VERSION='' would make
		# the guest script's ${NVIM_VERSION:-default} pointless noise.
		[ -n "${!var}" ] || continue
		case " $out " in *" ${var}="*) continue ;; esac
		out+="${var}=$(printf '%q' "${!var}") "
	done
	done
	printf '%s' "$out"
}

# run_provisioner <local script> <remote name> <env prefix> <label>
run_provisioner() {
	local src="$1" remote="$2" prefix="$3" label="$4"
	[ -f "$src" ] || die "$src not found"

	info "uploading $(basename "$src")"
	vm_scp "$src" "${VM_USER}@127.0.0.1:/tmp/${remote}" >/dev/null \
		|| die "upload of $src failed"

	local envs; envs=$(build_env "$prefix")
	info "running ${label} inside the VM (this takes a while — output is live)"
	vm_ssh_tty "chmod +x /tmp/${remote} && ${SUDO_CMD} env ${envs} bash /tmp/${remote}"
	local rc=${PIPESTATUS[0]}
	vm_ssh "rm -f /tmp/${remote}" >/dev/null 2>&1 || true
	[ "$rc" -eq 0 ] || warn "${label} exited ${rc} -- read the output above before trusting it"
}

show_health() {
	info "Neovim health report from the VM"
	vm_ssh 'nvim --version | head -n1' || warn "nvim not on PATH in the VM"
	local log="/home/${VM_USER}/.local/state/nvim/checkhealth.log"
	if vm_ssh "test -s '$log'"; then
		# Neovim decorates these with an emoji between the bullet and the word
		# ("- \u274c ERROR ...", "- \u26a0\ufe0f WARNING ..."), so an anchored '^- ERROR'
		# finds nothing and every report reads as clean.
		printf "\n${C_B}--- errors ---${C_R}\n"
		vm_ssh "grep -nE '^- .*\\bERROR\\b' '$log' || echo '(none)'"
		printf "\n${C_B}--- warnings ---${C_R}\n"
		vm_ssh "grep -nE '^- .*\\bWARNING\\b' '$log' || echo '(none)'"
		printf "\n${C_B}--- extras loaded ---${C_R}\n"
		# redir cannot target /dev/stdout when stdout is a pipe (E190), so it
		# goes to a temp file inside the VM which is then printed.
		vm_ssh "t=\$(mktemp); nvim --headless -c \"redir! > \$t\" -c 'silent B2BExtras' -c 'redir END' -c 'qa' >/dev/null 2>&1; cat \$t; rm -f \$t" \
			|| warn "could not run :B2BExtras"
		printf "\nFull report in the VM: %s\n" "$log"
	else
		warn "no checkhealth log yet — run: $0 $VM_NAME nvim"
	fi
}

# `health` only reads files, so it never needs to become root.
[ "$ACTION" = "health" ] || setup_sudo

case "$ACTION" in
	nvim)
		# Bootstrap once, from the extras step: kickstart's plugins and the
		# extras land in the same plugin directory, so downloading twice just
		# pays the cold-cache cost twice.
		NVIM_BOOTSTRAP=0 run_provisioner setup/install/nvim/install_nvim.sh \
			install_nvim.sh NVIM_ "Neovim + kickstart.nvim"
		run_provisioner setup/install/nvim/install_nvim_extras.sh \
			install_nvim_extras.sh NVIM_ "the Neovim extras layer"
		ok "Neovim provisioning finished"
		;;
	nvim-base)
		run_provisioner setup/install/nvim/install_nvim.sh \
			install_nvim.sh NVIM_ "Neovim + kickstart.nvim"
		ok "Neovim base provisioning finished"
		;;
	nvim-extras)
		run_provisioner setup/install/nvim/install_nvim_extras.sh \
			install_nvim_extras.sh NVIM_ "the Neovim extras layer"
		ok "Neovim extras provisioning finished"
		;;
	hellish)
		run_provisioner setup/install/hellish/install_hellish_plugins.sh \
			install_hellish_plugins.sh HELLISH_ "hellishrc plugin framework"
		ok "hellishrc plugin provisioning finished"
		;;
	shell)
		# Upstream's own installer, run inside the VM: the current hellish
		# release plus the plugin framework, with --yes taking every default.
		run_provisioner setup/install/hellish/install_hellish_upstream.sh \
			install_hellish_upstream.sh HELLISH_ "hellish from upstream"
		ok "hellish (upstream) provisioning finished"
		;;
	global)
		run_provisioner setup/install/tools/install_global_scope.sh \
			install_global_scope.sh GLOBAL_ "machine-wide scope on /opt"
		ok "global scope configured"
		;;
	devtools)
		run_provisioner setup/install/tools/install_devtools.sh \
			install_devtools.sh "HERDR_ INSTALL_ DEVTOOLS_" "Herdr + Claude Code"
		ok "devtools provisioning finished"
		;;
	ai)
		[ -n "${AI_MODE:-}" ] || die "set AI_MODE=client or AI_MODE=local (see setup/install/ai/install_ai.sh)"
		run_provisioner setup/install/ai/install_ai.sh \
			install_ai.sh AI_ "AI (AI_MODE=${AI_MODE})"
		ok "AI provisioning finished"
		;;
	health)
		show_health
		;;
	all)
		# Order matters: the npm prefix has to move to /opt BEFORE anything
		# runs `npm install -g`, or those packages are stranded at the old
		# prefix and fall off PATH when it changes.
		run_provisioner setup/install/tools/install_global_scope.sh \
			install_global_scope.sh GLOBAL_ "machine-wide scope on /opt"
		NVIM_BOOTSTRAP=0 run_provisioner setup/install/nvim/install_nvim.sh \
			install_nvim.sh NVIM_ "Neovim + kickstart.nvim"
		run_provisioner setup/install/nvim/install_nvim_extras.sh \
			install_nvim_extras.sh NVIM_ "the Neovim extras layer"
		run_provisioner setup/install/hellish/install_hellish_plugins.sh \
			install_hellish_plugins.sh HELLISH_ "hellishrc plugin framework"
		run_provisioner setup/install/tools/install_devtools.sh \
			install_devtools.sh "HERDR_ INSTALL_ DEVTOOLS_" "Herdr + Claude Code"
		# AI is opt-in: without AI_MODE this step does nothing at all.
		if [ -n "${AI_MODE:-}" ] && [ "${AI_MODE}" != "off" ]; then
			run_provisioner setup/install/ai/install_ai.sh \
				install_ai.sh AI_ "AI (AI_MODE=${AI_MODE})"
		else
			info "AI_MODE unset or off — skipping the AI step"
		fi
		show_health
		ok "provisioning finished"
		;;
	*)
		die "unknown action '$ACTION' (expected: nvim | nvim-base | nvim-extras | hellish | shell | global | devtools | ai | health | all)"
		;;
esac
