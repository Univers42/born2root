#!/usr/bin/env hellish

set -e # Exit on any error

# ── Locate the preseeded ISO (built by create_custom_iso.sh) ─────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$SCRIPT_DIR"
. "$SCRIPT_DIR/utils/vm_path.sh"

PRESEED_ISO=$(find "$(iso_dir)" -maxdepth 1 -name 'debian-*-amd64-*preseed.iso' 2>/dev/null | head -n1)
if [ -z "$PRESEED_ISO" ]; then
    echo "Error: No preseeded ISO found in $(iso_dir)"
    echo "Run 'make gen_iso' first."
    exit 1
fi

# Variables
#
# VM_NAME is taken from the environment or $1 so a second machine can be built
# beside an existing one. This USED to be hardcoded to "debian", which made the
# stale-VM removal below delete the running Born2beRoot VM no matter what name
# the caller asked for -- `make all VM_NAME=other` still wiped "debian".
VM_NAME="${VM_NAME:-${1:-debian}}"
case "$VM_NAME" in
'' | *[!A-Za-z0-9._-]*)
    echo "Error: invalid VM_NAME '$VM_NAME' (allowed: letters, digits, . _ -)" >&2
    exit 1
    ;;
esac
# default: project-local storage
VM_PATH="${VM_PATH:-$(pwd)/disk_images}"
# A root-owned VM_PATH is explained, and sudo offered only then, instead of
# the bare "Permission denied" this used to die with. See utils/vm_path.sh.
. "$SCRIPT_DIR/utils/vm_path.sh"
ensure_vm_dir "$VM_PATH" "$VM_NAME" || exit 1

ISO_PATH="$(readlink -f "$PRESEED_ISO")"
VM_DISK_PATH="$VM_PATH/$VM_NAME/$VM_NAME.vdi"
# Disk size in MB. The VDI is dynamically allocated, but treat this as a hard
# ceiling on what the VM can cost rather than a free upper bound: this used to
# default to 122880 (120 GB) on the theory that an unused disk costs nothing,
# and the QEMU image built from the same recipe reached 42.7 GB on the host
# because nothing in the guest ever handed freed blocks back. See the comment
# in preseeds/preseed.cfg.in for the full measurement.
#
# The Makefile derives this from SIZE_B2B (default 15 GB, the school quota);
# `make space` reports the footprint and fails a build that would exceed it.
# The recipe fully allocates the group, with /var last and unpinned, so raising
# this number grows /var.
VM_DISK_SIZE="${DISK_SIZE_MB:-15360}" # 15GB in MB (SIZE_B2B*1024)

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
    elif command -v sysctl >/dev/null 2>&1; then
        host_ram_mb=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024))
    fi
    : "${host_ram_mb:=8192}"

    # Detect host CPU cores
    if command -v nproc >/dev/null 2>&1; then
        host_cpus=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        host_cpus=$(grep -c ^processor /proc/cpuinfo)
    elif command -v sysctl >/dev/null 2>&1; then
        host_cpus=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    fi
    : "${host_cpus:=4}"

    # Allocate 25% RAM, clamp [2048, 8192].
    #
    # VM_RAM_MB overrides the whole calculation. It exists because the automatic
    # share is sized to keep the HOST responsive, which is the right default but
    # the wrong answer for a couple of real cases: running a local model
    # (setup/install/ai/install_ai.sh picks a model from this number, and on the
    # 2048 floor it correctly refuses to pull one at all), or several editors
    # with language servers at once. Raising it starves the host, so it is a
    # deliberate opt-in rather than a bigger default.
    VM_MEMORY=$((host_ram_mb / 4))
    [ "$VM_MEMORY" -lt 2048 ] && VM_MEMORY=2048
    [ "$VM_MEMORY" -gt 8192 ] && VM_MEMORY=8192
    if [ -n "${VM_RAM_MB:-}" ]; then
        case "$VM_RAM_MB" in
        '' | *[!0-9]*)
            echo "Warning: VM_RAM_MB='$VM_RAM_MB' is not a number — using ${VM_MEMORY}MB" >&2
            ;;
        *)
            if [ "$VM_RAM_MB" -lt 1024 ]; then
                echo "Warning: VM_RAM_MB=${VM_RAM_MB} is below 1024 — using ${VM_MEMORY}MB" >&2
            else
                VM_MEMORY="$VM_RAM_MB"
                if [ "$VM_MEMORY" -gt "$host_ram_mb" ]; then
                    echo "Warning: VM_RAM_MB=${VM_MEMORY} exceeds the host's ${host_ram_mb}MB" >&2
                fi
            fi
            ;;
        esac
    fi

    # Allocate 50% CPUs, clamp [2, 8]
    VM_CPUS=$((host_cpus / 2))
    [ "$VM_CPUS" -lt 2 ] && VM_CPUS=2
    [ "$VM_CPUS" -gt 8 ] && VM_CPUS=8
    case "${B2B_VM_CPUS:-}" in
    '' | 0 | *[!0-9]*) ;;
    *) VM_CPUS="$B2B_VM_CPUS" ;;
    esac

    VM_VRAM=128

    echo "╔══════════════════════════════════════════════╗"
    echo "║  Smart VM Sizing (host-adaptive)             ║"
    echo "╠══════════════════════════════════════════════╣"
    printf "║  Host:  %5d MB RAM  /  %2d cores            ║\n" "$host_ram_mb" "$host_cpus"
    printf "║  VM:    %5d MB RAM  /  %2d cores  (25%%/50%%) ║\n" "$VM_MEMORY" "$VM_CPUS"
    echo "╚══════════════════════════════════════════════╝"
}

auto_size_vm

# ── Dynamic port allocation (find free host ports) ───────────────────────────
. "$SCRIPT_DIR/utils/host_ports.sh"
# [network] forwards (the port list) and the login for the ssh hint below.
. "$SCRIPT_DIR/utils/b2b_config.sh"

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
    local_state=$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null |
        grep "^VMState=" | cut -d'"' -f2)
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
        # Delete VirtualBox's OWN files, not the directory. The QEMU backend
        # keeps its qcow2, its serial log and its .installed stamp in this
        # same disk_images/<vm>/ folder (setup/host/qemu_vm.sh), so a blanket
        # rm -rf here destroys a working QEMU VM that has nothing to do with
        # the stale VirtualBox registration being cleaned up.
        rm -rf "$VM_PATH/$VM_NAME"/*.vbox "$VM_PATH/$VM_NAME"/*.vbox-prev \
            "$VM_PATH/$VM_NAME"/*.vdi "$VM_PATH/$VM_NAME"/Logs \
            "$VM_PATH/$VM_NAME"/Snapshots 2>/dev/null || true
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

# ── Do not let the VM take the host's sound card ────────────────────────────
# Left unset, VirtualBox picks its own host audio backend, and on a Linux
# desktop it picks ALSA and opens the raw device about ten seconds into the
# guest's boot ("ALSA: Using output device \"default\"" in VBox.log). It then
# holds that device for the whole life of the VM.
#
# PipeWire releases the card when nothing is playing, so the next time the user
# plays anything it has to reopen it -- and gets EBUSY:
#
#     spa.alsa: 'front:0': playback open failed: Device or resource busy
#     pw.node: (alsa_output.pci-...-analog-stereo) suspended -> error
#
# The node then stays in error and retries every 5s forever, so host sound is
# dead until the VM exits, and applications that open audio *block* rather than
# fail fast -- which is why browsers and calls feel broken too, not just sound.
#
# Measured on this host, not assumed. Host up 6h49m with clean audio; first VM
# start 19:00:57 -> first EBUSY 19:02:37; last EBUSY 00:42:30 -> VM powered off
# 00:42:31, one second later, and sound came back. Confirmed A/B/C with a silent
# 2s file: VM on + audio enabled = pw-play hangs (exit 124); VM off = exit 0;
# VM on + audio disabled = exit 0, and VBox.log never opens an ALSA device.
#
# Turning it off costs nothing: this is a headless server VM and VirtualBox was
# already configured with playback and capture both disabled, so the emulated
# AC97 never carried sound in either direction. It only held the device.
#
# --audio-enabled is the 7.x spelling; --audio none is the 6.x one. Try both so
# this keeps working on an older VirtualBox instead of silently leaving audio on.
print_header "Disabling VM audio (it holds the host sound card hostage)"
if VBoxManage modifyvm "$VM_NAME" --audio-enabled off 2>/dev/null ||
    VBoxManage modifyvm "$VM_NAME" --audio none 2>/dev/null; then
    echo "  Audio device removed from the guest; host sound stays with the host"
else
    echo "  Warning: could not disable VM audio -- host sound may cut out while the VM runs" >&2
fi

# ── Serial console: the headless install's only window ──────────────────────
# The run is headless end to end, so nothing renders the VGA console. Wire
# COM1 to a file and the Debian installer (booted with console=ttyS0, see
# generate/create_custom_iso.sh) writes every step into it as plain text.
# That file is what `make console` tails and what the orchestrator parses to
# report the real install stage instead of guessing from elapsed time.
print_header "Wiring serial console to a log file"
SERIAL_LOG="$VM_PATH/$VM_NAME/serial.log"
: >"$SERIAL_LOG"
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

# Idempotently add a NAT port-forward rule: drop any existing rule of the same
# name first, so re-running setup — or a VM that kept old rules from a previous,
# partially-removed instance — never aborts with "A NAT rule of this name already
# exists". Args: <name> <host_port> <guest_port> (all rules are tcp).
#
# Every rule binds NATPF_BIND, not the empty host IP VirtualBox defaults to. An
# empty host IP means 0.0.0.0: all 34 forwards were listening on every interface,
# so the guest's ssh (4242), MariaDB (3307), Redis (6380), Vault (18200) and the
# rest were reachable from the whole LAN the moment the VM booted -- on a host
# whose own firewall is off by default ("Status: inactive", iptables INPUT
# ACCEPT, checked on this machine). Loopback is what every consumer in this repo
# already uses: ~/.ssh/config points at 127.0.0.1, and so does the markdown
# preview tunnel. Override only if a LAN device genuinely needs to reach the VM.
NATPF_BIND="${NATPF_BIND:-127.0.0.1}"
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
            --natpf1 "${name},tcp,${NATPF_BIND},${host_port},,${guest_port}" 2>&1); then
            return 0
        fi
        case "$out" in
        *"lock request pending"* | *VBOX_E_INVALID_OBJECT_STATE*)
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

# Every rule is a [network] forwards entry in born2root.toml ("name:host:guest"),
# the same list QEMU's hostfwd and the guest's UFW are built from. The host
# port walks up past one already taken; resolve_host_port reserves each pick
# against the next, so two rules never land on one host port.
NATPF_RULES=""
HOST_SSH_PORT=""
for B2B_FWD in $(b2b_get B2B_FORWARDS); do
    B2B_FWD_NAME=${B2B_FWD%%:*}
    B2B_FWD_GUEST=${B2B_FWD##*:}
    B2B_FWD_HOST=${B2B_FWD#*:}
    B2B_FWD_HOST=${B2B_FWD_HOST%%:*}
    resolve_host_port B2B_FWD_HOST_PORT "$B2B_FWD_HOST"
    add_natpf "$B2B_FWD_NAME" "$B2B_FWD_HOST_PORT" "$B2B_FWD_GUEST"
    NATPF_RULES="${NATPF_RULES}${B2B_FWD_NAME} ${B2B_FWD_HOST_PORT} ${B2B_FWD_GUEST}
"
    if [ "$B2B_FWD_NAME" = ssh ]; then
        HOST_SSH_PORT=$B2B_FWD_HOST_PORT
    fi
done
if [ -z "$HOST_SSH_PORT" ]; then
    echo "No ssh forward in [network] forwards -- run: utils/b2b_config.sh --check" >&2
    exit 1
fi
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

# Record the machine that owns this disk. The repo lives on a shared NFS home,
# so the same disk_images/ directory is visible from every workstation -- but
# the VM only ever runs on one of them. Destructive targets read -r this stamp so
# a run here cannot silently delete a VM that belongs to another machine.
printf '%s (kernel %s, %s)\n' "$(hostname -f 2>/dev/null || hostname)" \
    "$(uname -r)" "$(date '+%Y-%m-%d %H:%M:%S')" \
    >"$VM_PATH/$VM_NAME/.built-on" 2>/dev/null || true

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
echo "Port Forwarding Configuration ([network] forwards):"
printf '%s' "$NATPF_RULES" | while read -r rule_name rule_host rule_guest; do
    printf '  - %-26s Host %s:%s -> Guest :%s\n' "$rule_name" "$NATPF_BIND" "$rule_host" "$rule_guest"
done
echo ""
echo "Next Steps:"
echo "  1. Start the VM:"
echo "     VBoxManage startvm \"$VM_NAME\" --type headless"
echo ""
echo "  2. SSH into your VM from host:"
echo "     ssh -p ${HOST_SSH_PORT} $(b2b_get B2B_LOGIN)@127.0.0.1"
echo ""
