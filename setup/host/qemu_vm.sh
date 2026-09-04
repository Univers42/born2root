#!/usr/bin/env bash
# ============================================================================ #
#  qemu_vm.sh — run the Born2beRoot VM with QEMU/KVM instead of VirtualBox     #
# ============================================================================ #
#
# WHY THIS EXISTS
#   VirtualBox needs its own kernel module (vboxdrv), and loading a kernel
#   module needs root. On a campus machine where vboxdrv.service failed at
#   boot, that is the end of the road: `make all` cannot start a VM and you
#   cannot fix it without an admin.
#
#   KVM is different. It is *in* the mainline kernel, so nothing has to be
#   built or inserted -- it only has to be reachable, and reachability is a
#   file permission on /dev/kvm. On this machine 42 granted it by ACL:
#
#       $ getfacl /dev/kvm
#       user:dlesieur:rw-          <-- us, explicitly, without the kvm group
#
#   So a full hardware-accelerated VM is available to an ordinary user on a
#   machine where VirtualBox is unusable. That is what this script drives.
#
# WHAT IT KEEPS IDENTICAL TO THE VIRTUALBOX PATH
#   guest disk       /dev/sda        an AHCI/SATA controller, so the preseed's
#                                    `partman-auto/disk string /dev/sda` is
#                                    still correct and needs no edit
#   networking       10.0.2.2 host   QEMU's user-mode ("SLIRP") gateway is the
#                                    same address VirtualBox NAT uses, so
#                                    AI_MODE=client and every doc still hold
#   port forwards    hostfwd=        same host:guest pairs as the NAT rules
#   serial console   a plain file    what `make console` already tails
#   headless         -display none   no window, ever
#   LUKS unlock      monitor sendkey the same trick as VirtualBox's
#                                    `keyboardputstring`, over QEMU's monitor
#
# WHAT IS DELIBERATELY NOT SHARED
#   The disk is qcow2, not VDI, and lives beside it as <vm>.qcow2. A VirtualBox
#   build on another machine is therefore untouched by anything here -- both
#   can exist in the same disk_images/<vm>/ directory without interfering.
#
# USAGE
#   qemu_vm.sh create      create the qcow2 disk (no-op if it exists)
#   qemu_vm.sh install     boot the preseed ISO and run the unattended install
#   qemu_vm.sh start       boot from disk, headless, and unlock LUKS
#   qemu_vm.sh unlock      type the passphrase at a waiting LUKS prompt
#   qemu_vm.sh stop        ACPI power button, then wait
#   qemu_vm.sh kill        last resort: SIGTERM the QEMU process
#   qemu_vm.sh status      pid, ports, disk size, what the console last said
#   qemu_vm.sh console     follow the serial log
#   qemu_vm.sh ssh-config  write the ~/.ssh/config b2b block for these ports
#
# Env
#   VM_NAME (debian)  VM_PATH (./disk_images)  DISK_SIZE_MB (122880)
#   VM_RAM_MB (2048)  VM_CPUS (3)  VM_PASS (read from vm_pass.txt)
#   ISO (newest debian-*preseed.iso in the repo root)
# ============================================================================ #

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

VM_NAME="${VM_NAME:-debian}"
VM_PATH="${VM_PATH:-$REPO_ROOT/disk_images}"
VM_DIR="$VM_PATH/$VM_NAME"
DISK="$VM_DIR/$VM_NAME.qcow2"
SERIAL="$VM_DIR/serial.log"
MONITOR="$VM_DIR/monitor.sock"
PIDFILE="$VM_DIR/qemu.pid"

DISK_SIZE_MB="${DISK_SIZE_MB:-122880}"
VM_RAM_MB="${VM_RAM_MB:-2048}"
VM_CPUS="${VM_CPUS:-3}"

# Host:guest port pairs, matching the VirtualBox NAT rule set.
PORTS_SPEC="${PORTS_SPEC:-ssh:4242:4242 http:8082:80 https:8443:443 inception-static:8090:8090 inception-adminer:8081:8080 mariadb:3306:3306 frontend:5173:5173 backend:3000:3000}"

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
	C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_DIM=''
fi
ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
info() { printf "  ${C_BLUE}▶${C_RESET} %s\n" "$*"; }
warn() { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; }
die()  { printf "  ${C_RED}✗${C_RESET} %s\n" "$*" >&2; exit 1; }

QEMU=$(command -v qemu-system-x86_64 || true)
[ -n "$QEMU" ] || die "qemu-system-x86_64 not installed"

# ── Is KVM usable by THIS user? ─────────────────────────────────────────────
# Membership in the kvm group is the usual route, but an ACL grant works just
# as well and is what this machine has -- so test the thing that matters
# (can we open it read-write?) rather than the thing that usually implies it.
kvm_ok() { [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; }

ACCEL="tcg"
if kvm_ok; then
	ACCEL="kvm"
fi

find_iso() {
	[ -n "${ISO:-}" ] && { printf '%s' "$ISO"; return 0; }
	ls -1t "$REPO_ROOT"/debian-*-amd64-*preseed.iso 2> /dev/null | head -1
}

vm_pass() {
	[ -n "${VM_PASS:-}" ] && { printf '%s' "$VM_PASS"; return 0; }
	[ -r "$REPO_ROOT/vm_pass.txt" ] && head -n1 "$REPO_ROOT/vm_pass.txt" | tr -d '\r\n'
}

qemu_pid() {
	[ -r "$PIDFILE" ] || return 1
	local p; p=$(head -n1 "$PIDFILE" 2> /dev/null)
	[ -n "$p" ] && kill -0 "$p" 2> /dev/null && printf '%s' "$p"
}

is_running() { qemu_pid > /dev/null 2>&1; }

# ── The QEMU monitor ────────────────────────────────────────────────────────
# A unix socket speaking QEMU's human monitor protocol. Used for sendkey (the
# LUKS passphrase) and system_powerdown (the ACPI power button).
mon() {
	local cmd="$1"
	[ -S "$MONITOR" ] || return 1
	python3 - "$MONITOR" "$cmd" << 'PYEOF' 2> /dev/null
import socket, sys, time
sock, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(sock)
time.sleep(0.2)
try: s.recv(65536)
except Exception: pass
s.sendall((cmd + "\n").encode())
time.sleep(0.2)
try: sys.stdout.write(s.recv(65536).decode(errors="replace"))
except Exception: pass
s.close()
PYEOF
}

# One QEMU keyname per character. Only what a passphrase needs; anything
# unmapped is reported rather than silently dropped, because a passphrase that
# is silently wrong looks exactly like a VM that will not boot.
sendkey_string() {
	local s="$1" i ch key
	for (( i = 0; i < ${#s}; i++ )); do
		ch="${s:$i:1}"
		case "$ch" in
			[a-z0-9]) key="$ch" ;;
			[A-Z])    key="shift-$(printf '%s' "$ch" | tr 'A-Z' 'a-z')" ;;
			'-')      key="minus" ;;
			'_')      key="shift-minus" ;;
			'.')      key="dot" ;;
			',')      key="comma" ;;
			'/')      key="slash" ;;
			'=')      key="equal" ;;
			'+')      key="shift-equal" ;;
			' ')      key="spc" ;;
			'!')      key="shift-1" ;;
			'@')      key="shift-2" ;;
			'#')      key="shift-3" ;;
			'$')      key="shift-4" ;;
			'%')      key="shift-5" ;;
			'&')      key="shift-7" ;;
			'*')      key="shift-8" ;;
			'?')      key="shift-slash" ;;
			':')      key="shift-semicolon" ;;
			';')      key="semicolon" ;;
			*) warn "no keymap for '$ch' — passphrase would be wrong, aborting"; return 1 ;;
		esac
		mon "sendkey $key" > /dev/null
		sleep 0.03
	done
	mon "sendkey ret" > /dev/null
}

build_hostfwd() {
	local spec name hp gp out=""
	for spec in $PORTS_SPEC; do
		name="${spec%%:*}"; hp="${spec#*:}"; gp="${hp#*:}"; hp="${hp%%:*}"
		out="${out},hostfwd=tcp:127.0.0.1:${hp}-:${gp}"
	done
	printf '%s' "$out"
}

# ── Launch ──────────────────────────────────────────────────────────────────
# $1 = "cdrom" to boot the installer, "disk" to boot the installed system.
launch() {
	local boot="$1" iso cd_args=() hd_index=1 cd_index=2

	mkdir -p "$VM_DIR"
	[ -f "$DISK" ] || die "no disk yet — run: $0 create"

	if [ "$boot" = "cdrom" ]; then
		iso=$(find_iso)
		[ -n "$iso" ] && [ -f "$iso" ] || die "no preseed ISO found — run: make gen_iso"
		hd_index=2; cd_index=1
		cd_args=(
			-drive "file=${iso},if=none,id=cd0,media=cdrom,readonly=on"
			-device "ide-cd,drive=cd0,bus=ahci.1,bootindex=${cd_index}"
		)
		info "booting the installer from $(basename "$iso")"
	else
		info "booting from disk"
	fi

	# Truncate the console log so `make console` shows THIS boot, not the last.
	: > "$SERIAL"
	rm -f "$MONITOR"

	# Publish the forwards. A QEMU hostfwd= lives only on the command line, so
	# without this the Inception host-access scripts -- which ask VBoxManage
	# for a named NAT rule -- would conclude nothing is forwarded, and report
	# "no 'https' NAT rule" about a port that works. See vm_ports.sh.
	: > "$VM_DIR/ports.env"
	for _spec in $PORTS_SPEC; do
		_n="${_spec%%:*}"; _rest="${_spec#*:}"
		printf '%s=%s\n' "$_n" "${_rest%%:*}" >> "$VM_DIR/ports.env"
	done

	# -device ich9-ahci gives the guest a SATA controller, so the disk appears
	# as /dev/sda and preseed.cfg's partman recipe applies unchanged. virtio
	# would be faster but shows up as /dev/vda and would silently not match.
	"$QEMU" \
		-name "$VM_NAME" \
		-machine "pc,accel=${ACCEL}" \
		$( [ "$ACCEL" = "kvm" ] && printf '%s' "-cpu host" ) \
		-smp "$VM_CPUS" \
		-m "$VM_RAM_MB" \
		-device ich9-ahci,id=ahci \
		-drive "file=${DISK},if=none,id=hd0,format=qcow2,cache=writeback,discard=unmap" \
		-device "ide-hd,drive=hd0,bus=ahci.0,bootindex=${hd_index}" \
		"${cd_args[@]}" \
		-netdev "user,id=net0$(build_hostfwd)" \
		-device e1000,netdev=net0 \
		-device virtio-rng-pci \
		-serial "file:${SERIAL}" \
		-monitor "unix:${MONITOR},server=on,wait=off" \
		-display none \
		-daemonize \
		-no-reboot \
		-pidfile "$PIDFILE" \
		|| die "QEMU failed to start"

	sleep 1
	is_running || die "QEMU exited immediately — see $SERIAL"
	ok "QEMU running (pid $(qemu_pid), accel=${ACCEL})"
}

wait_for_serial() {
	local needle="$1" timeout="${2:-600}" deadline
	deadline=$(( $(date +%s) + timeout ))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		grep -qa -- "$needle" "$SERIAL" 2> /dev/null && return 0
		is_running || return 2
		sleep 3
	done
	return 1
}

# ── Actions ─────────────────────────────────────────────────────────────────
case "${1:-status}" in
	create)
		mkdir -p "$VM_DIR"
		if [ -f "$DISK" ]; then
			ok "disk already exists: $DISK ($(du -h "$DISK" | cut -f1) on host)"
		else
			qemu-img create -f qcow2 "$DISK" "${DISK_SIZE_MB}M" > /dev/null \
				|| die "qemu-img create failed"
			ok "created $DISK (${DISK_SIZE_MB}MB virtual, grows on demand)"
		fi
		printf '%s (qemu/kvm, kernel %s, %s)\n' "$(hostname -f 2> /dev/null || hostname)" \
			"$(uname -r)" "$(date '+%Y-%m-%d %H:%M:%S')" > "$VM_DIR/.built-on" 2> /dev/null || true
		;;

	install)
		is_running && die "already running (pid $(qemu_pid)) — stop it first"
		launch cdrom
		printf "\n  ${C_BOLD}Unattended install running.${C_RESET} Follow it with: %s console\n\n" "$0"
		# finish-install writes B2B-INSTALL-COMPLETE to ttyS0, then d-i halts.
		if wait_for_serial "B2B-INSTALL-COMPLETE" "${INSTALL_TIMEOUT:-3600}"; then
			ok "installer reported completion"
		else
			case $? in
				2) ok "QEMU exited — the installer finished and powered the VM off" ;;
				*) warn "timed out waiting for the completion marker; check: $0 console" ;;
			esac
		fi
		# d-i halts rather than powering off cleanly in some paths.
		if is_running; then
			info "waiting for the VM to power itself off"
			for _ in $(seq 1 60); do is_running || break; sleep 5; done
			is_running && { mon "system_powerdown" > /dev/null; sleep 10; }
			is_running && { kill "$(qemu_pid)" 2> /dev/null; sleep 2; }
		fi
		rm -f "$PIDFILE"
		ok "install phase done — boot it with: $0 start"
		;;

	start)
		if is_running; then
			ok "already running (pid $(qemu_pid))"
		else
			launch disk
		fi
		# The LUKS prompt is drawn by the guest's initramfs, long before any
		# network exists, so the keyboard is the only channel that can answer
		# it -- exactly as unlock_vm.sh does with VirtualBox.
		# The LUKS prompt CANNOT be waited for on the serial log. b2b-setup.sh
		# sets GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8 console=tty0",
		# and Linux gives /dev/console to the LAST console listed -- tty0. So
		# kernel printk reaches the serial log but cryptsetup's prompt, which is
		# userspace in the initramfs, is drawn on the VGA text screen only.
		#
		# So do what unlock_vm.sh does under VirtualBox: type blind, then prove
		# it worked by the SSH banner, and retry if it did not. Typing the
		# passphrase at a prompt that is not ready yet is harmless -- the
		# characters are discarded, and the next attempt types it again.
		pass=$(vm_pass)
		ssh_port=$(printf '%s' "$PORTS_SPEC" | tr ' ' '\n' | awk -F: '$1=="ssh"{print $2}')

		ssh_banner_up() {
			local b
			b=$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${ssh_port} && head -c 40 <&3" 2> /dev/null)
			case "$b" in *SSH-2.0*) printf '%s' "${b%%$'\r'*}"; return 0 ;; esac
			return 1
		}

		if [ -z "$pass" ]; then
			warn "no passphrase (set VM_PASS or vm_pass.txt) — unlock it yourself"
		else
			info "waiting for the initramfs to reach the LUKS prompt"
			sleep "${UNLOCK_DELAY:-45}"
			for attempt in 1 2 3 4; do
				is_running || die "QEMU exited while booting — see $SERIAL"
				if ssh_banner_up > /dev/null; then break; fi
				info "typing the passphrase over the QEMU monitor (attempt ${attempt})"
				sendkey_string "$pass" || break
				# Unlocking, then booting to sshd, takes a while on first boot.
				for _ in $(seq 1 24); do
					sleep 5
					is_running || die "QEMU exited while booting — see $SERIAL"
					ssh_banner_up > /dev/null && break
				done
				ssh_banner_up > /dev/null && break
				warn "still locked after attempt ${attempt} — retrying"
			done
		fi

		# Readiness is the SSH BANNER, not an open port: the hostfwd listener
		# accepts connections whether or not sshd is up, so a bare port check
		# reports success against a VM that is still sitting at the LUKS prompt.
		info "waiting for sshd on 127.0.0.1:${ssh_port}"
		for _ in $(seq 1 120); do
			if b=$(ssh_banner_up); then ok "sshd is up: $b"; break; fi
			is_running || die "QEMU exited while booting — see $SERIAL"
			sleep 5
		done
		ssh_banner_up > /dev/null || warn "sshd never answered — look at the screen: $0 screenshot"
		;;

	screenshot)
		# The VGA text screen is where the LUKS prompt and any boot error live,
		# precisely because they do not reach the serial log (see above).
		is_running || die "not running"
		out="${2:-$VM_DIR/screen.ppm}"
		mon "screendump $out" > /dev/null
		sleep 1
		[ -s "$out" ] || die "screendump produced nothing"
		if command -v python3 > /dev/null 2>&1 && python3 -c 'import PIL' 2> /dev/null; then
			python3 -c "from PIL import Image; Image.open('$out').save('${out%.ppm}.png')" 2> /dev/null \
				&& ok "screen: ${out%.ppm}.png"
		else
			ok "screen: $out (PPM)"
		fi
		;;

	unlock)
		is_running || die "not running"
		pass=$(vm_pass); [ -n "$pass" ] || die "no passphrase available"
		sendkey_string "$pass" && ok "passphrase sent"
		;;

	stop)
		is_running || { ok "not running"; exit 0; }
		info "ACPI power button"
		mon "system_powerdown" > /dev/null
		for _ in $(seq 1 40); do is_running || break; sleep 2; done
		if is_running; then
			warn "still up after 80s — sending SIGTERM"
			kill "$(qemu_pid)" 2> /dev/null; sleep 3
		fi
		rm -f "$PIDFILE" "$MONITOR"
		ok "stopped"
		;;

	kill)
		p=$(qemu_pid) && { kill "$p" 2> /dev/null; sleep 2; kill -9 "$p" 2> /dev/null; }
		rm -f "$PIDFILE" "$MONITOR"
		ok "killed"
		;;

	console)
		[ -f "$SERIAL" ] || die "no serial log yet"
		printf "  ${C_DIM}Ctrl+C stops watching, not the VM${C_RESET}\n\n"
		tail -f "$SERIAL"
		;;

	ssh-config)
		ssh_port=$(printf '%s' "$PORTS_SPEC" | tr ' ' '\n' | awk -F: '$1=="ssh"{print $2}')
		mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
		touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
		marker="# Born2beRoot VM (auto-generated, qemu)"
		python3 - "$HOME/.ssh/config" "$marker" "$ssh_port" << 'PYEOF'
import sys
path, marker, port = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split("\n")
out, skip = [], False
for ln in lines:
    if ln.strip() == marker:
        skip = True; continue
    if skip:
        if ln.startswith("#") or (ln and not ln[0].isspace() and not ln.startswith("Host")):
            skip = False
        elif ln.startswith("Host ") and "b2b" not in ln:
            skip = False
        else:
            continue
    out.append(ln)
block = [marker, "Host b2b vm born2beroot", "    HostName 127.0.0.1",
         f"    Port {port}", "    User dlesieur",
         "    ServerAliveInterval 15", "    ServerAliveCountMax 6",
         "    TCPKeepAlive yes", "    ConnectionAttempts 5", "    ConnectTimeout 15",
         "    StrictHostKeyChecking no", "    UserKnownHostsFile /dev/null",
         "    LogLevel ERROR", ""]
text = "\n".join([l for l in out if l is not None]).rstrip("\n") + "\n\n" + "\n".join(block)
open(path, "w").write(text)
print("wrote the b2b block for port " + port)
PYEOF
		ok "ssh b2b now points at 127.0.0.1:${ssh_port}"
		;;

	status)
		printf "\n${C_BOLD}QEMU VM: %s${C_RESET}\n" "$VM_NAME"
		printf "  %-12s %s\n" "accel:" "$ACCEL$( [ "$ACCEL" = tcg ] && printf ' (NO KVM — emulated, very slow)' )"
		printf "  %-12s %s\n" "/dev/kvm:" "$( kvm_ok && echo 'usable by us' || echo 'NOT usable' )"
		if is_running; then
			printf "  %-12s ${C_GREEN}running${C_RESET} (pid %s)\n" "state:" "$(qemu_pid)"
		else
			printf "  %-12s stopped\n" "state:"
		fi
		[ -f "$DISK" ] && printf "  %-12s %s (%s on host)\n" "disk:" "$DISK" "$(du -h "$DISK" 2>/dev/null | cut -f1)"
		printf "  %-12s %s\n" "iso:" "$(basename "$(find_iso)" 2>/dev/null || echo none)"
		printf "  %-12s " "ports:"; printf '%s' "$PORTS_SPEC" | tr ' ' '\n' | awk -F: '{printf "%s→%s ", $2, $3}'; printf "\n"
		if [ -f "$SERIAL" ]; then
			printf "  %-12s %s\n" "console:" "$(tail -c 400 "$SERIAL" 2>/dev/null | tr -d '\r' | grep -a . | tail -1 | cut -c1-70)"
		fi
		printf "\n"
		;;

	*) die "unknown action '${1}' (create|install|start|unlock|stop|kill|status|console|screenshot|ssh-config)" ;;
esac
