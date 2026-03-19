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

# ── Dynamic port allocation (find free host ports) ───────────────────────────
# Check if a host port is available (no sudo required)
is_port_free() {
	local port="$1"
	if (ss -tln 2> /dev/null || netstat -tln 2> /dev/null) | grep -qE "(0\.0\.0\.0|\*|\[::\]):${port}\b"; then
		return 1 # port is taken
	fi
	return 0 # port is free
}

# Find a free port starting from a preferred one, incrementing until one works
find_free_port() {
	local port="$1"
	local max_tries=100
	local i=0
	while [ "$i" -lt "$max_tries" ]; do
		if is_port_free "$port"; then
			echo "$port"
			return 0
		fi
		port=$((port + 1))
		i=$((i + 1))
	done
	echo "Error: Could not find a free port starting from $1" >&2
	return 1
}

# Resolve actual host ports (may differ from defaults if ports are taken)
HOST_SSH_PORT=$(find_free_port "$SSH_PORT")
HOST_HTTP_PORT=$(find_free_port 8082)
HOST_HTTPS_PORT=$(find_free_port 8443)
HOST_DOCKER_PORT=$(find_free_port 5000)
HOST_MARIADB_PORT=$(find_free_port 3306)
HOST_REDIS_PORT=$(find_free_port 6379)
HOST_FRONTEND_PORT=$(find_free_port "$FRONTEND_PORT")
HOST_BACKEND_PORT=$(find_free_port "$BACKEND_PORT")

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

VBoxManage modifyvm "$VM_NAME" --natpf1 "ssh,tcp,,${HOST_SSH_PORT},,${SSH_PORT}" || {
	echo "Failed to set up NAT port forwarding for SSH"
	exit 1
}
VBoxManage modifyvm "$VM_NAME" --natpf1 "http,tcp,,${HOST_HTTP_PORT},,${HTTP_PORT}" || {
	echo "Failed to set up NAT port forwarding for HTTP"
	exit 1
}
VBoxManage modifyvm "$VM_NAME" --natpf1 "https,tcp,,${HOST_HTTPS_PORT},,${HTTPS_PORT}" || {
	echo "Failed to set up NAT port forwarding for HTTPS"
	exit 1
}
VBoxManage modifyvm "$VM_NAME" --natpf1 "docker,tcp,,${HOST_DOCKER_PORT},,${DOCKER_REGISTRY_PORT}" || {
	echo "Failed to set up NAT port forwarding for Docker Registry"
	exit 1
}
VBoxManage modifyvm "$VM_NAME" --natpf1 "mariadb,tcp,,${HOST_MARIADB_PORT},,${MARIADB_PORT}" || {
	echo "Failed to set up NAT port forwarding for MariaDB"
	exit 1
}
VBoxManage modifyvm "$VM_NAME" --natpf1 "redis,tcp,,${HOST_REDIS_PORT},,${REDIS_PORT}" || {
	echo "Failed to set up NAT port forwarding for Redis"
	exit 1
}
VBoxManage modifyvm "$VM_NAME" --natpf1 "frontend,tcp,,${HOST_FRONTEND_PORT},,${FRONTEND_PORT}" || {
	echo "Failed to set up NAT port forwarding for Frontend"
	exit 1
}
VBoxManage modifyvm "$VM_NAME" --natpf1 "backend,tcp,,${HOST_BACKEND_PORT},,${BACKEND_PORT}" || {
	echo "Failed to set up NAT port forwarding for Backend"
	exit 1
}
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
echo ""
echo "  4. Other services from host:"
echo "     WordPress:       http://127.0.0.1:${HOST_HTTP_PORT}/wordpress"
echo "     MariaDB:         mysql -h 127.0.0.1 -P ${HOST_MARIADB_PORT} -u root -p"
echo "     Docker Registry: http://127.0.0.1:${HOST_DOCKER_PORT}"
echo ""
