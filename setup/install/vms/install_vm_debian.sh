#!/bin/bash

set -e # Exit on any error

# ── Locate the preseeded ISO (built by create_custom_iso.sh) ─────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$SCRIPT_DIR"

PRESEED_ISO=$(ls -1 debian-*-amd64-*preseed.iso 2> /dev/null | head -n1)
if [ -z "$PRESEED_ISO" ]; then
	echo "Error: No preseeded ISO found in $SCRIPT_DIR"
	echo "Run 'make gen_iso' first."
	exit 1
fi

# Variables
VM_NAME="debian"
VM_PATH="$(pwd)/disk_images"
ISO_PATH="$(pwd)/$PRESEED_ISO"
VM_DISK_PATH="$VM_PATH/$VM_NAME/$VM_NAME.vdi"
VM_DISK_SIZE=64000 # 64GB in MB

# ── Smart VM sizing algorithm ────────────────────────────────────────────────
# Detects host hardware and allocates resources proportionally.
# Rules:
#   - RAM: 25% of host RAM, clamped to [2048, 8192] MB
#   - CPUs: 50% of host cores, clamped to [2, 8]
#   - VRAM: 128 MB (server, no GUI in guest)
# This keeps the host responsive while giving the VM enough power.
auto_size_vm() {
	local host_ram_mb host_cpus

	# Detect host RAM (MB)
	if [ -f /proc/meminfo ]; then
		host_ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
	elif command -v sysctl > /dev/null 2>&1; then
		host_ram_mb=$(($(sysctl -n hw.memsize 2> /dev/null || echo 0) / 1024 / 1024))
	fi
	: "${host_ram_mb:=8192}"

	# Detect host CPU cores
	if command -v nproc > /dev/null 2>&1; then
		host_cpus=$(nproc)
	elif [ -f /proc/cpuinfo ]; then
		host_cpus=$(grep -c ^processor /proc/cpuinfo)
	elif command -v sysctl > /dev/null 2>&1; then
		host_cpus=$(sysctl -n hw.ncpu 2> /dev/null || echo 4)
	fi
	: "${host_cpus:=4}"

	# Allocate 25% RAM, clamp [2048, 8192]
	VM_MEMORY=$((host_ram_mb / 4))
	[ "$VM_MEMORY" -lt 2048 ] && VM_MEMORY=2048
	[ "$VM_MEMORY" -gt 8192 ] && VM_MEMORY=8192

	# Allocate 50% CPUs, clamp [2, 8]
	VM_CPUS=$((host_cpus / 2))
	[ "$VM_CPUS" -lt 2 ] && VM_CPUS=2
	[ "$VM_CPUS" -gt 8 ] && VM_CPUS=8

	VM_VRAM=128

	echo "╔══════════════════════════════════════════════╗"
	echo "║  Smart VM Sizing (host-adaptive)             ║"
	echo "╠══════════════════════════════════════════════╣"
	printf "║  Host:  %5d MB RAM  /  %2d cores            ║\n" "$host_ram_mb" "$host_cpus"
	printf "║  VM:    %5d MB RAM  /  %2d cores  (25%%/50%%) ║\n" "$VM_MEMORY" "$VM_CPUS"
	echo "╚══════════════════════════════════════════════╝"
}

auto_size_vm

SSH_PORT=4242
HTTP_PORT=80
HTTPS_PORT=443

DOCKER_REGISTRY_PORT=5000
MARIADB_PORT=3306
REDIS_PORT=6379

# Vite Gourmand / ft_transcendence development ports
FRONTEND_PORT=5173
BACKEND_PORT=3000

# osionos / ft_transcendence HTTPS proxy ports
OSIONOS_APP_PORT=3001
OSIONOS_MAIL_PORT=3002
OSIONOS_CALENDAR_PORT=3003
OSIONOS_BRIDGE_PORT=4000
MAIL_BRIDGE_PORT=4100
CALENDAR_BRIDGE_PORT=4200
WEBSITE_PORT=4322
BAAS_GATEWAY_PORT=8000
BAAS_ADMIN_PORT=8001
MAILPIT_PORT=8025
AUTH_GATEWAY_PORT=8787
VAULT_PORT=18200

# ── Dynamic port allocation (find free host ports) ───────────────────────────
. "$SCRIPT_DIR/utils/host_ports.sh"

# Resolve the actual host ports (they differ from the defaults when a port is
# already taken on this host). resolve_host_port assigns into the named variable
# so each pick is reserved against the following ones: two services landing on
# the same host port is what VirtualBox refuses to forward.
resolve_host_port HOST_SSH_PORT              "$SSH_PORT"
resolve_host_port HOST_HTTP_PORT             8082
resolve_host_port HOST_HTTPS_PORT            8443
resolve_host_port HOST_DOCKER_PORT           5000
resolve_host_port HOST_MARIADB_PORT          3306
resolve_host_port HOST_REDIS_PORT            6379
resolve_host_port HOST_FRONTEND_PORT         "$FRONTEND_PORT"
resolve_host_port HOST_BACKEND_PORT          "$BACKEND_PORT"
resolve_host_port HOST_OSIONOS_APP_PORT      "$OSIONOS_APP_PORT"
resolve_host_port HOST_OSIONOS_MAIL_PORT     "$OSIONOS_MAIL_PORT"
resolve_host_port HOST_OSIONOS_CALENDAR_PORT "$OSIONOS_CALENDAR_PORT"
resolve_host_port HOST_OSIONOS_BRIDGE_PORT   "$OSIONOS_BRIDGE_PORT"
resolve_host_port HOST_MAIL_BRIDGE_PORT      "$MAIL_BRIDGE_PORT"
resolve_host_port HOST_CALENDAR_BRIDGE_PORT  "$CALENDAR_BRIDGE_PORT"
resolve_host_port HOST_WEBSITE_PORT          "$WEBSITE_PORT"
resolve_host_port HOST_BAAS_GATEWAY_PORT     "$BAAS_GATEWAY_PORT"
resolve_host_port HOST_BAAS_ADMIN_PORT       "$BAAS_ADMIN_PORT"
resolve_host_port HOST_MAILPIT_PORT          "$MAILPIT_PORT"
resolve_host_port HOST_AUTH_GATEWAY_PORT     "$AUTH_GATEWAY_PORT"
resolve_host_port HOST_VAULT_PORT            "$VAULT_PORT"

# Create VM folders if they don't exist
mkdir -p "$VM_PATH/$VM_NAME"

# Function to print headers
print_header() {
	echo ""
	echo "==============================================="
	echo "  $1"
	echo "==============================================="
}

print_header "Setting up Born2beRoot VirtualBox VM"

# Debug information for troubleshooting
print_header "DEBUG INFO"
echo "Checking for existing VMs:"
VBoxManage list vms

# If a stale VM with the same name exists, force-remove it before creating fresh
if VBoxManage list vms | grep -q "\"$VM_NAME\""; then
	print_header "Removing stale VM \"$VM_NAME\" before fresh creation"
	# Power off if running
	local_state=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null \
		| grep "^VMState=" | cut -d'"' -f2)
	if [ "$local_state" = "running" ] || [ "$local_state" = "paused" ]; then
		echo "  VM is $local_state — powering off..."
		VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
		sleep 3
		# Wait for session lock to release
		for _i in $(seq 1 10); do
			VBoxManage modifyvm "$VM_NAME" --description "" 2>/dev/null && break
			sleep 1
		done
	fi
	VBoxManage unregistervm "$VM_NAME" --delete 2>/dev/null || {
		echo "  --delete failed, unregistering and cleaning files manually"
		VBoxManage unregistervm "$VM_NAME" 2>/dev/null || true
		rm -rf "$VM_PATH/$VM_NAME" 2>/dev/null || true
	}
	echo "  ✓ Stale VM removed"
fi

print_header "Creating new VM"

echo "Using preseeded ISO: $PRESEED_ISO"
echo "ISO path: $ISO_PATH"

# Create the VM
print_header "Creating VirtualBox VM"
VBoxManage createvm --name "$VM_NAME" --ostype "Debian_64" --basefolder "$VM_PATH" --register || {
	echo "Failed to create VM"
	exit 1
}

# Set memory, CPU, and display
print_header "Configuring VM hardware settings"
VBoxManage modifyvm "$VM_NAME" \
	--memory "$VM_MEMORY" \
	--vram "$VM_VRAM" \
	--cpus "$VM_CPUS" \
	--acpi on \
	--ioapic on \
	--rtcuseutc on \
	--clipboard bidirectional \
	--draganddrop bidirectional || {
	echo "Failed to set VM hardware"
	exit 1
}

# ── Serial console: the headless install's only window ──────────────────────
# The run is headless end to end, so nothing renders the VGA console. Wire
# COM1 to a file and the Debian installer (booted with console=ttyS0, see
# generate/create_custom_iso.sh) writes every step into it as plain text.
# That file is what `make console` tails and what the orchestrator parses to
# report the real install stage instead of guessing from elapsed time.
print_header "Wiring serial console to a log file"
SERIAL_LOG="$VM_PATH/$VM_NAME/serial.log"
: > "$SERIAL_LOG"
VBoxManage modifyvm "$VM_NAME" --uart1 0x3F8 4 --uartmode1 file "$SERIAL_LOG" || {
	echo "Warning: could not attach serial console (install progress will be time-only)"
}
echo "  Serial console: $SERIAL_LOG"

# ── Fix git clone / large download hanging at ~44% ──────────────────────────
# VirtualBox NAT engine has small default TCP socket send/receive buffers
# (64 KB) which cause stalls on large HTTPS transfers like git clone.
# Increasing these to 1 MB fixes the issue completely.
# Also set a sane MTU to avoid fragmentation issues.
print_header "Tuning NAT engine for reliable downloads"
VBoxManage modifyvm "$VM_NAME" --nat-settings1 1500,128,128,0,0 || true
# nat-settings1: MTU, socksnd, sockrcv, TcpWndSnd, TcpWndRcv
# MTU=1500 (standard), sock buffers=128KB each, TCP windows=0 (auto)

# Extra: increase DNS proxy reliability (prevents DNS timeouts in NAT)
VBoxManage modifyvm "$VM_NAME" --nat-dns-host-resolver1 on || true

# Set network - NAT with port forwarding
print_header "Configuring network and port forwarding"
VBoxManage modifyvm "$VM_NAME" --nic1 nat || {
	echo "Failed to set VM network"
	exit 1
}

# Set up NAT port forwarding (using dynamically resolved free host ports)
echo "  SSH:      host:${HOST_SSH_PORT} -> guest:${SSH_PORT}"
echo "  HTTP:     host:${HOST_HTTP_PORT} -> guest:${HTTP_PORT}"
echo "  HTTPS:    host:${HOST_HTTPS_PORT} -> guest:${HTTPS_PORT}"
echo "  Docker:   host:${HOST_DOCKER_PORT} -> guest:${DOCKER_REGISTRY_PORT}"
echo "  MariaDB:  host:${HOST_MARIADB_PORT} -> guest:${MARIADB_PORT}"
echo "  Redis:    host:${HOST_REDIS_PORT} -> guest:${REDIS_PORT}"
echo "  Frontend: host:${HOST_FRONTEND_PORT} -> guest:${FRONTEND_PORT}"
echo "  Backend:  host:${HOST_BACKEND_PORT} -> guest:${BACKEND_PORT}"
echo "  Website:  host:${HOST_WEBSITE_PORT} -> guest:${WEBSITE_PORT}"
echo "  osionos app:      host:${HOST_OSIONOS_APP_PORT} -> guest:${OSIONOS_APP_PORT}"
echo "  osionos mail:     host:${HOST_OSIONOS_MAIL_PORT} -> guest:${OSIONOS_MAIL_PORT}"
echo "  osionos calendar: host:${HOST_OSIONOS_CALENDAR_PORT} -> guest:${OSIONOS_CALENDAR_PORT}"
echo "  osionos bridge:   host:${HOST_OSIONOS_BRIDGE_PORT} -> guest:${OSIONOS_BRIDGE_PORT}"
echo "  Mail bridge:      host:${HOST_MAIL_BRIDGE_PORT} -> guest:${MAIL_BRIDGE_PORT}"
echo "  Calendar bridge:  host:${HOST_CALENDAR_BRIDGE_PORT} -> guest:${CALENDAR_BRIDGE_PORT}"
echo "  BaaS gateway:     host:${HOST_BAAS_GATEWAY_PORT} -> guest:${BAAS_GATEWAY_PORT}"
echo "  BaaS admin:       host:${HOST_BAAS_ADMIN_PORT} -> guest:${BAAS_ADMIN_PORT}"
echo "  Mailpit:          host:${HOST_MAILPIT_PORT} -> guest:${MAILPIT_PORT}"
echo "  Auth gateway:     host:${HOST_AUTH_GATEWAY_PORT} -> guest:${AUTH_GATEWAY_PORT}"
echo "  Vault:            host:${HOST_VAULT_PORT} -> guest:${VAULT_PORT}"

# Idempotently add a NAT port-forward rule: drop any existing rule of the same
# name first, so re-running setup — or a VM that kept old rules from a previous,
# partially-removed instance — never aborts with "A NAT rule of this name already
# exists". Args: <name> <host_port> <guest_port> (all rules are tcp).
NATPF_HOST_PORTS=""
add_natpf() {
	local name="$1" host_port="$2" guest_port="$3"

	# Self-check: two rules on one host port is exactly what VirtualBox rejects
	# with "A NAT rule for this host port and this host IP already exists". Name
	# the offending rule here instead of leaving a bare VBoxManage error.
	case " $NATPF_HOST_PORTS " in
		*" $host_port "*)
			echo "Internal error: rule '${name}' reuses host port ${host_port}" >&2
			exit 1
			;;
	esac
	NATPF_HOST_PORTS="${NATPF_HOST_PORTS} ${host_port}"

	VBoxManage modifyvm "$VM_NAME" --natpf1 delete "$name" >/dev/null 2>&1 || true

	# Twenty of these run back to back, and VBoxSVC does not always release the
	# machine's write lock before the next one asks for it — the result is
	# "The machine 'debian' already has a lock request pending", which used to
	# abort the whole build a few seconds before the install would have started.
	# It is purely a timing problem, so retry it.
	local attempt out
	for attempt in 1 2 3 4 5 6; do
		if out=$(VBoxManage modifyvm "$VM_NAME" \
				--natpf1 "${name},tcp,,${host_port},,${guest_port}" 2>&1); then
			return 0
		fi
		case "$out" in
			*"lock request pending"*|*VBOX_E_INVALID_OBJECT_STATE*)
				sleep 2
				;;
			*)
				echo "Failed to set up NAT port forwarding for ${name}"
				printf '%s\n' "$out" >&2
				exit 1
				;;
		esac
	done
	echo "Failed to set up NAT port forwarding for ${name} after ${attempt} attempts"
	printf '%s\n' "$out" >&2
	exit 1
}

add_natpf ssh              "${HOST_SSH_PORT}"              "${SSH_PORT}"
add_natpf http             "${HOST_HTTP_PORT}"             "${HTTP_PORT}"
add_natpf https            "${HOST_HTTPS_PORT}"            "${HTTPS_PORT}"
add_natpf docker           "${HOST_DOCKER_PORT}"           "${DOCKER_REGISTRY_PORT}"
add_natpf mariadb          "${HOST_MARIADB_PORT}"          "${MARIADB_PORT}"
add_natpf redis            "${HOST_REDIS_PORT}"            "${REDIS_PORT}"
add_natpf frontend         "${HOST_FRONTEND_PORT}"         "${FRONTEND_PORT}"
add_natpf backend          "${HOST_BACKEND_PORT}"          "${BACKEND_PORT}"
add_natpf website          "${HOST_WEBSITE_PORT}"          "${WEBSITE_PORT}"
add_natpf osionos-app      "${HOST_OSIONOS_APP_PORT}"      "${OSIONOS_APP_PORT}"
add_natpf osionos-mail     "${HOST_OSIONOS_MAIL_PORT}"     "${OSIONOS_MAIL_PORT}"
add_natpf osionos-calendar "${HOST_OSIONOS_CALENDAR_PORT}" "${OSIONOS_CALENDAR_PORT}"
add_natpf osionos-bridge   "${HOST_OSIONOS_BRIDGE_PORT}"   "${OSIONOS_BRIDGE_PORT}"
add_natpf mail-bridge      "${HOST_MAIL_BRIDGE_PORT}"      "${MAIL_BRIDGE_PORT}"
add_natpf calendar-bridge  "${HOST_CALENDAR_BRIDGE_PORT}"  "${CALENDAR_BRIDGE_PORT}"
add_natpf baas-gateway     "${HOST_BAAS_GATEWAY_PORT}"     "${BAAS_GATEWAY_PORT}"
add_natpf baas-admin       "${HOST_BAAS_ADMIN_PORT}"       "${BAAS_ADMIN_PORT}"
add_natpf mailpit          "${HOST_MAILPIT_PORT}"          "${MAILPIT_PORT}"
add_natpf auth-gateway     "${HOST_AUTH_GATEWAY_PORT}"     "${AUTH_GATEWAY_PORT}"
add_natpf vault            "${HOST_VAULT_PORT}"            "${VAULT_PORT}"
# Create disk if it does not exist
if [ ! -f "$VM_DISK_PATH" ]; then
	print_header "Creating virtual disk"
	VBoxManage createmedium disk --filename "$VM_DISK_PATH" --size "$VM_DISK_SIZE" || {
		echo "Failed to create virtual disk"
		exit 1
	}
else
	print_header "Virtual disk already exists - Keeping existing disk"
fi

# Add controllers and attach devices
print_header "Setting up storage controllers"
VBoxManage storagectl "$VM_NAME" --name "SATA Controller" --add sata --controller IntelAHCI || {
	echo "Failed to add SATA controller"
	exit 1
}
VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "$VM_DISK_PATH" || {
	echo "Failed to attach virtual disk"
	exit 1
}

VBoxManage storagectl "$VM_NAME" --name "IDE Controller" --add ide || {
	echo "Failed to add IDE controller"
	exit 1
}
VBoxManage storageattach "$VM_NAME" --storagectl "IDE Controller" --port 0 --device 0 --type dvddrive --medium "$ISO_PATH" || {
	echo "Failed to attach ISO"
	exit 1
}

# Set boot order (DVD first for installation, then disk)
print_header "Setting boot order"
VBoxManage modifyvm "$VM_NAME" --boot1 dvd --boot2 disk --boot3 none --boot4 none || {
	echo "Failed to set boot order"
	exit 1
}

# Enable nested virtualization (optional, for advanced use)
VBoxManage modifyvm "$VM_NAME" --nested-hw-virt on || true

print_header "VM Setup Complete"
echo ""
echo "Port Forwarding Configuration:"
echo "  - SSH:       Host 127.0.0.1:${HOST_SSH_PORT} -> Guest :${SSH_PORT}"
echo "  - HTTP:      Host 127.0.0.1:${HOST_HTTP_PORT} -> Guest :${HTTP_PORT}"
echo "  - HTTPS:     Host 127.0.0.1:${HOST_HTTPS_PORT} -> Guest :${HTTPS_PORT}"
echo "  - Frontend:  Host 127.0.0.1:${HOST_FRONTEND_PORT} -> Guest :${FRONTEND_PORT}"
echo "  - Backend:   Host 127.0.0.1:${HOST_BACKEND_PORT} -> Guest :${BACKEND_PORT}"
echo "  - Website:   Host 127.0.0.1:${HOST_WEBSITE_PORT} -> Guest :${WEBSITE_PORT}"
echo "  - osionos:   Host 127.0.0.1:${HOST_OSIONOS_APP_PORT}/${HOST_OSIONOS_MAIL_PORT}/${HOST_OSIONOS_CALENDAR_PORT} -> Guest :${OSIONOS_APP_PORT}/${OSIONOS_MAIL_PORT}/${OSIONOS_CALENDAR_PORT}"
echo "  - Bridges:   Host 127.0.0.1:${HOST_OSIONOS_BRIDGE_PORT}/${HOST_MAIL_BRIDGE_PORT}/${HOST_CALENDAR_BRIDGE_PORT} -> Guest :${OSIONOS_BRIDGE_PORT}/${MAIL_BRIDGE_PORT}/${CALENDAR_BRIDGE_PORT}"
echo "  - BaaS/Auth: Host 127.0.0.1:${HOST_BAAS_GATEWAY_PORT}/${HOST_AUTH_GATEWAY_PORT} -> Guest :${BAAS_GATEWAY_PORT}/${AUTH_GATEWAY_PORT}"
echo "  - Mailpit:   Host 127.0.0.1:${HOST_MAILPIT_PORT} -> Guest :${MAILPIT_PORT}"
echo "  - Vault:     Host 127.0.0.1:${HOST_VAULT_PORT} -> Guest :${VAULT_PORT}"
echo "  - Docker:    Host 127.0.0.1:${HOST_DOCKER_PORT} -> Guest :${DOCKER_REGISTRY_PORT}"
echo "  - MariaDB:   Host 127.0.0.1:${HOST_MARIADB_PORT} -> Guest :${MARIADB_PORT}"
echo "  - Redis:     Host 127.0.0.1:${HOST_REDIS_PORT} -> Guest :${REDIS_PORT}"
echo ""
echo "Next Steps:"
echo "  1. Start the VM:"
echo "     VBoxManage startvm \"$VM_NAME\" --type headless"
echo ""
echo "  2. SSH into your VM from host:"
echo "     ssh -p ${HOST_SSH_PORT} dlesieur@127.0.0.1"
echo ""
echo "  3. Access Vite Gourmand from host:"
echo "     Frontend:  http://127.0.0.1:${HOST_FRONTEND_PORT}"
echo "     Backend:   http://127.0.0.1:${HOST_BACKEND_PORT}/api"
echo "     API Docs:  http://127.0.0.1:${HOST_BACKEND_PORT}/api/docs"
echo "     Website:   https://127.0.0.1:${HOST_WEBSITE_PORT}"
echo "     osionos:   https://127.0.0.1:${HOST_OSIONOS_APP_PORT}"
echo ""
echo "  4. Other services from host:"
echo "     WordPress:       http://127.0.0.1:${HOST_HTTP_PORT}/wordpress"
echo "     MariaDB:         mysql -h 127.0.0.1 -P ${HOST_MARIADB_PORT} -u root -p"
echo "     Docker Registry: http://127.0.0.1:${HOST_DOCKER_PORT}"
echo ""
