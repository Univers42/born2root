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
# Reads the installer's own progress off serial.log (shared with orchestrate.sh).
. "$HERE/di_progress.sh"

VM_NAME="${VM_NAME:-debian}"
VM_PATH="${VM_PATH:-$REPO_ROOT/disk_images}"
VM_DIR="$VM_PATH/$VM_NAME"
DISK="$VM_DIR/$VM_NAME.qcow2"
SERIAL="$VM_DIR/serial.log"
MONITOR="$VM_DIR/monitor.sock"
PIDFILE="$VM_DIR/qemu.pid"
# What the disk holds is recorded, not guessed from its size: a qcow2 grows
# past 1 GB minutes into an install, long before there is a system on it.
PHASE="$VM_DIR/.phase"       # "installing" while d-i owns the disk
STAMP="$VM_DIR/.installed"   # written once B2B-INSTALL-COMPLETE arrived

DISK_SIZE_MB="${DISK_SIZE_MB:-122880}"
VM_RAM_MB="${VM_RAM_MB:-2048}"
VM_CPUS="${VM_CPUS:-3}"

# Host:guest port pairs, matching the VirtualBox NAT rule set. These are
# PREFERRED host ports, not guaranteed ones -- see resolve_ports() below.
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
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	[ -n "$QEMU" ] || die "qemu-system-x86_64 not installed"
fi

# ── Is KVM usable by THIS user? ─────────────────────────────────────────────
# Membership in the kvm group is the usual route, but an ACL grant works just
# as well and is what this machine has -- so test the thing that matters
# (can we open it read-write?) rather than the thing that usually implies it.
kvm_ok() { [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; }

# Being allowed to open /dev/kvm is necessary, not sufficient. VT-x belongs to
# one hypervisor at a time: while a VirtualBox VM runs, KVM_CREATE_VM returns
# EBUSY and QEMU dies with "Device or resource busy". kvm_probe.sh performs
# that exact call and says why it failed, so launch() can refuse with a real
# reason instead of a raw ioctl error -- and never silently drop to TCG.
kvm_why() { bash "$HERE/kvm_probe.sh"; }

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

# ── Guests of this VM started from ANOTHER VM_PATH ──────────────────────────
# Every path above is keyed on VM_PATH, so `make qemu_stop` run without the
# VM_PATH the build used looks at the wrong pidfile, finds nothing, and said
# "✓ not running" while the VM kept running -- and kept holding VT-x, so the
# next `make all` reported VirtualBox "blocked" with the culprit invisible.
# Happened here twice in one afternoon. QEMU is always started with -name
# VM_NAME and -pidfile <VM_PATH>/<VM_NAME>/qemu.pid, so both the guest and
# the VM_PATH it belongs to can be recovered from its own command line.
#
# "<pid> <cmdline>" per running qemu-system-x86_64. The one seam tests
# override. -x matches the 15-char comm name, so a shell whose ARGUMENTS
# mention qemu (a grep, this script itself) can never match.
qemu_cmdlines() {
	local pid
	for pid in $(pgrep -x qemu-system-x86 2> /dev/null); do
		printf '%s %s\n' "$pid" "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2> /dev/null)"
	done
}

# "<pid> <VM_PATH>" per guest named VM_NAME whose pidfile is not ours.
other_guests() {
	local pid args pf
	qemu_cmdlines | while read -r pid args; do
		case " $args" in *" -name ${VM_NAME} "*) ;; *) continue ;; esac
		pf=${args##* -pidfile }; pf=${pf%% *}
		[ "${pf##*/}" = qemu.pid ] || continue
		[ "$pf" = "$PIDFILE" ] && continue
		printf '%s %s\n' "$pid" "$(dirname "$(dirname "$pf")")"
	done
}

# Say where the running guests are and how to reach them. Returns 0 if there
# were any -- the caller then must NOT claim success.
report_other_guests() {
	local others pid path
	others=$(other_guests)
	[ -n "$others" ] || return 1
	warn "nothing is running at $VM_DIR, but QEMU '$VM_NAME' IS running from another VM_PATH:"
	printf '%s\n' "$others" | while read -r pid path; do
		printf "     pid %-8s VM_PATH=%s\n" "$pid" "$path"
		printf "     ${C_DIM}stop it:  VM_PATH=%s make qemu_stop${C_RESET}\n" "$path"
	done
	return 0
}

# ── Host port collision avoidance ───────────────────────────────────────────
# The same problem the VirtualBox path already solves (utils/host_ports.sh):
# on a real dev machine SOMETHING is usually already on 3306/3000/5173/etc,
# and QEMU's -netdev takes every hostfwd= as one argument -- ONE busy port
# fails the whole netdev, not just that one forward, and the VM never boots.
# Reproduced on this repo: an unrelated Docker container already held 3306,
# and `make all` died with "Could not set up host forwarding rule" instead of
# picking another port the way the VirtualBox NAT rules already do.
. "$REPO_ROOT/utils/host_ports.sh"

# Walk PORTS_SPEC ("name:preferred_host:guest ...") to the host ports this run
# will actually use, bumping past anything already listening. Sets
# RESOLVED_SPEC as "name:actual_host:guest ..."; resolve_host_port reserves
# each pick against the rest so two services in this spec can never collide
# with EACH OTHER either.
RESOLVED_SPEC=""
resolve_ports() {
	local spec name hp gp actual out=""
	for spec in $PORTS_SPEC; do
		name="${spec%%:*}"; hp="${spec#*:}"; gp="${hp#*:}"; hp="${hp%%:*}"
		resolve_host_port actual "$hp" || die "no free host port near ${hp} for '${name}'"
		[ "$actual" != "$hp" ] && warn "host port ${hp} (${name}) is already in use -- using ${actual} instead"
		out="${out} ${name}:${actual}:${gp}"
	done
	RESOLVED_SPEC="${out# }"
}

# The host port actually forwarding a given name. While ports.env exists it is
# authoritative -- by then QEMU itself holds the port, so re-probing "is it
# free?" would see its own listener and wrongly walk to a different one. Only
# before any launch is there nothing to be authoritative about yet.
host_port_of() {
	local name="$1"
	if [ -r "$VM_DIR/ports.env" ]; then
		awk -F= -v n="$name" '$1==n{print $2; exit}' "$VM_DIR/ports.env"
		return
	fi
	[ -n "$RESOLVED_SPEC" ] || resolve_ports
	printf '%s\n' "$RESOLVED_SPEC" | tr ' ' '\n' | awk -F: -v n="$name" '$1==n{print $2; exit}'
}

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
out = b""; t0 = time.time()
while time.time() - t0 < 4:
    try: chunk = s.recv(65536)
    except Exception: break
    if not chunk: break
    out += chunk
    if out.rstrip().endswith(b"(qemu)"): break
sys.stdout.write(out.decode(errors="replace"))
s.close()
PYEOF
}

# ── Has the guest shut itself down? ─────────────────────────────────────────
# A Linux kernel that has stopped parks every CPU with interrupts disabled and
# halts it (stop_this_cpu: cli; hlt). Nothing can wake it again. An idle kernel
# also sits in HLT, but with interrupts ENABLED, and the next timer tick wakes
# it -- so HLT alone would call a busy-but-waiting installer "finished".
# RFL bit 9 (0x200) is the interrupt flag, so the test that separates the two
# is: every vCPU has HLT=1 and IF=0.
#
# This is the normal end of a d-i install: the preseed sets exit/halt, and
# busybox's halt does not raise a real ACPI power button, so QEMU keeps running
# a machine whose CPUs will never execute another instruction.
guest_halted() {
	local regs line rfl hlt n=0 halted=0
	regs=$(mon "info registers -a") || return 1
	while IFS= read -r line; do
		rfl=${line#*RFL=}; rfl=${rfl%% *}
		hlt=${line##*HLT=}; hlt=${hlt:0:1}
		case "$rfl" in *[!0-9a-fA-F]* | "") continue ;; esac
		n=$((n + 1))
		[ "$hlt" = 1 ] && [ $((16#$rfl & 0x200)) -eq 0 ] && halted=$((halted + 1))
	done <<< "$(printf '%s\n' "$regs" | grep -E 'RFL=[0-9a-f]+ .*HLT=[01]')"
	[ "$n" -gt 0 ] && [ "$halted" -eq "$n" ]
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
	for spec in $RESOLVED_SPEC; do
		name="${spec%%:*}"; hp="${spec#*:}"; gp="${hp#*:}"; hp="${hp%%:*}"
		out="${out},hostfwd=tcp:127.0.0.1:${hp}-:${gp}"
	done
	printf '%s' "$out"
}

# ── Launch ──────────────────────────────────────────────────────────────────
# $1 = "cdrom" to boot the installer, "disk" to boot the installed system.
launch() {
	local boot="$1" iso cd_args=() cpu_args=() hd_index=1 cd_index=2
	# Same array idiom as cd_args: an empty array expands to nothing, where an
	# empty string would hand QEMU a bogus "" argument under TCG.
	[ "$ACCEL" = kvm ] && cpu_args=(-cpu host)

	mkdir -p "$VM_DIR"
	[ -f "$DISK" ] || die "no disk yet — run: $0 create"

	# Check KVM before touching anything (the serial log is truncated below).
	if [ "$ACCEL" = "kvm" ]; then
		local why
		if ! why=$(kvm_why); then
			printf "  ${C_RED}✗${C_RESET} KVM %s\n" "$why" >&2
			printf "    ${C_DIM}QEMU and VirtualBox cannot both run a VM on this host at once.${C_RESET}\n" >&2
			printf "    ${C_DIM}Either wait for / stop the VirtualBox VM:  VBoxManage controlvm <name> acpipowerbutton${C_RESET}\n" >&2
			printf "    ${C_DIM}or build with it instead:                  make all BACKEND=virtualbox${C_RESET}\n" >&2
			die "cannot start QEMU with KVM"
		fi
	fi

	resolve_ports

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
	for _spec in $RESOLVED_SPEC; do
		_n="${_spec%%:*}"; _rest="${_spec#*:}"
		printf '%s=%s\n' "$_n" "${_rest%%:*}" >> "$VM_DIR/ports.env"
	done

	# -device ich9-ahci gives the guest a SATA controller, so the disk appears
	# as /dev/sda and preseed.cfg's partman recipe applies unchanged. virtio
	# would be faster but shows up as /dev/vda and would silently not match.
	"$QEMU" \
		-name "$VM_NAME" \
		-machine "pc,accel=${ACCEL}" \
		"${cpu_args[@]}" \
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
		-pidfile "$PIDFILE" \
		|| die "QEMU failed to start"

	sleep 1
	is_running || die "QEMU exited immediately — see $SERIAL"
	ok "QEMU running (pid $(qemu_pid), accel=${ACCEL})"
}

# ── Watch the unattended install ────────────────────────────────────────────
# A headless install shows nothing, and nothing reads as "hung" long before the
# ~20 minutes are up. So watch it, and say what is happening from evidence:
#
#   serial.log   the installer's own syslog. preseed.cfg's early_command
#                streams it to ttyS0 (see di_progress.sh), so the current d-i
#                stage, the package being unpacked, any failed step, and the
#                B2B-INSTALL-COMPLETE marker all arrive here within a second.
#   qcow2 size   grows while the guest writes: partitioning, debootstrap, apt.
#   QEMU CPU     from /proc/<pid>/stat. Near 0% with nothing else moving means
#                the installer is waiting -- on a dialog nobody can answer.
#
# Returns 0 once the marker arrives. Returns 1 as soon as d-i reports a failed
# step, when QEMU exits before the marker, when nothing at all has moved for
# INSTALL_STALL_TIMEOUT seconds, or at INSTALL_TIMEOUT. On 1 the VM is left
# running so `screenshot` and `console` can show what it is stuck on.
# Ctrl+C only detaches; `qemu_vm.sh watch` re-attaches to a running install.
cpu_ticks() { awk '{print $14 + $15}' "/proc/$1/stat" 2> /dev/null || echo 0; }
human() { numfmt --to=iec "${1:-0}" 2> /dev/null || printf '%s' "${1:-0}"; }

watch_install() {
	local timeout="${INSTALL_TIMEOUT:-3600}" tick=2
	local stall_warn="${INSTALL_STALL_WARN:-120}" stall_fail="${INSTALL_STALL_TIMEOUT:-600}"
	local pid started elapsed=0 quiet=0 hz failed
	local stage="Booting the installer" prev_stage="" stage_started=0 changed=0 activity=""
	local log_sz=0 disk_sz=0 last_log=-1 last_disk=-1 cpu=0 cpu_prev cpu_now
	local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
	local fi=0 tty=0 drawn=0 last_beat=-60

	pid=$(qemu_pid) || { warn "no QEMU running for $VM_NAME"; return 1; }
	[ -t 1 ] && tty=1
	hz=$(getconf CLK_TCK 2> /dev/null || echo 100)
	# Age of the install from QEMU's own start, so a re-attach does not say 0s.
	started=$(stat -c %Y "$PIDFILE" 2> /dev/null || date +%s)
	cpu_prev=$(cpu_ticks "$pid")

	# Three live lines redrawn in place. Without a terminal: one line per stage
	# change plus a heartbeat every minute, so a captured log still shows life.
	draw() {
		local m=$((elapsed / 60)) s=$((elapsed % 60)) l1 l2 l3
		l1=$(printf "  ${C_BLUE}%s${C_RESET} ${C_BOLD}%s${C_RESET}  ${C_DIM}%dm%02ds${C_RESET}" \
			"${frames[$fi]}" "$stage" "$m" "$s")
		l2=$(printf "    ${C_DIM}%.72s${C_RESET}" "$activity")
		l3=$(printf "    ${C_DIM}disk %s · log %s · cpu %d%%${C_RESET}" \
			"$(human "$disk_sz")" "$(human "$log_sz")" "$cpu")
		[ "$quiet" -ge "$stall_warn" ] \
			&& l3="$l3  ${C_YELLOW}⚠ quiet for $((quiet / 60))m$((quiet % 60))s${C_RESET}"
		fi=$(( (fi + 1) % ${#frames[@]} ))
		if [ "$tty" = 1 ]; then
			[ "$drawn" = 1 ] && printf '\033[3A'
			printf '\r\033[K%s\n\r\033[K%s\n\r\033[K%s\n' "$l1" "$l2" "$l3"
			drawn=1
		elif [ "$changed" = 1 ] || [ $((elapsed - last_beat)) -ge 60 ]; then
			printf '  ▶ %dm%02ds  %s — %s\n' "$m" "$s" "$stage" "$activity"
			last_beat=$elapsed
		fi
		changed=0
	}
	# A finished stage becomes a permanent ✓ line above the live block.
	settle() {
		local took=$((elapsed - stage_started))
		if [ "$tty" = 1 ]; then
			[ "$drawn" = 1 ] && printf '\033[3A'
			printf '\r\033[K'
		fi
		printf "  ${C_GREEN}✓${C_RESET} %s  ${C_DIM}%dm%02ds${C_RESET}\n" \
			"$prev_stage" $((took / 60)) $((took % 60))
		if [ "$tty" = 1 ] && [ "$drawn" = 1 ]; then printf '\r\033[K\n\r\033[K\n\033[2A'; fi
		drawn=0
	}
	# The final word replaces the live block.
	finish() { # ok|fail, headline, detail
		if [ "$tty" = 1 ] && [ "$drawn" = 1 ]; then
			printf '\033[3A\r\033[K\n\r\033[K\n\r\033[K\n\033[3A'
		fi
		if [ "$1" = ok ]; then ok "$2"; else printf "  ${C_RED}✗${C_RESET} %s\n" "$2" >&2; fi
		[ -n "${3:-}" ] && printf "    ${C_DIM}%s${C_RESET}\n" "$3"
		drawn=0
	}

	while :; do
		sleep "$tick"
		elapsed=$(( $(date +%s) - started ))

		# The definitive signals come from inside the installer.
		if di_install_complete "$SERIAL"; then
			prev_stage=$stage; settle
			finish ok "installer reported completion after $((elapsed / 60))m$((elapsed % 60))s"
			return 0
		fi
		if ! is_running; then
			finish fail "QEMU exited before the installer finished" "last stage: $stage — see $SERIAL"
			return 1
		fi
		if failed=$(di_failed_step "$SERIAL"); then
			finish fail "the installer failed: $failed" \
				"d-i is waiting on an error dialog nobody can answer. Look: $0 screenshot  |  $0 console"
			return 1
		fi

		# Where is it, and is anything moving?
		stage=$(di_current_stage "$SERIAL") || stage="Booting the installer"
		activity=$(di_last_activity "$SERIAL") || activity="(no installer output yet)"
		if [ "$stage" != "$prev_stage" ]; then
			[ -n "$prev_stage" ] && settle
			prev_stage=$stage; stage_started=$elapsed; changed=1
		fi
		log_sz=$(stat -c %s "$SERIAL" 2> /dev/null || echo 0)
		disk_sz=$(stat -c %s "$DISK" 2> /dev/null || echo 0)
		cpu_now=$(cpu_ticks "$pid")
		cpu=$(( (cpu_now - cpu_prev) * 100 / (hz * tick) )); cpu_prev=$cpu_now
		if [ "$log_sz" != "$last_log" ] || [ "$disk_sz" != "$last_disk" ] || [ "$cpu" -ge 5 ]; then
			quiet=0
		else
			quiet=$((quiet + tick))
		fi
		last_log=$log_sz; last_disk=$disk_sz

		# Quiet for a while: has the guest actually stopped? d-i ends on
		# `halt`, so a halted guest AFTER its last hook is a finished install
		# whose marker went missing -- an ISO built before the marker hook was
		# created early enough to run. Halted BEFORE it is a kernel that died.
		# Checked every 10s rather than every tick: it costs a monitor query.
		if [ "$quiet" -ge "$stall_warn" ] && [ $((quiet % 10)) -eq 0 ] && guest_halted; then
			if di_reached_final_unmount "$SERIAL"; then
				prev_stage=$stage; settle
				finish ok "the installer ran its last step and halted the guest after $((elapsed / 60))m$((elapsed % 60))s" \
					"no completion marker on the serial port: this ISO predates the marker fix — rebuild it with  make gen_iso FORCE_ISO=1"
				return 0
			fi
			finish fail "the guest halted before the installer's last step (a kernel panic looks like this)" \
				"last stage: $stage. Look: $0 screenshot  |  $0 console"
			return 1
		fi
		# Silence right after an error-worded line is d-i sitting on an error
		# dialog (partman: "too small for expert recipe"). Say so now, not
		# after the full stall timeout.
		if [ "$quiet" -ge "$stall_warn" ] && di_looks_like_error "$activity"; then
			finish fail "the installer stopped right after: $activity" \
				"nothing has moved for $((quiet / 60))m$((quiet % 60))s since. Look: $0 screenshot  |  $0 console"
			return 1
		fi
		if [ "$quiet" -ge "$stall_fail" ]; then
			finish fail "nothing has moved for $((quiet / 60)) minutes: no log lines, no disk writes, no CPU" \
				"the installer is stuck. Look: $0 screenshot  |  $0 console   (INSTALL_STALL_TIMEOUT=$stall_fail)"
			return 1
		fi
		if [ "$elapsed" -ge "$timeout" ]; then
			finish fail "still not finished after $((elapsed / 60)) minutes (INSTALL_TIMEOUT=$timeout)" \
				"it is still moving, so this may just be slow: re-attach with  $0 watch"
			return 1
		fi
		draw
	done
}

# ── Actions ─────────────────────────────────────────────────────────────────
# Guarded so tests/test_qemu_ports.sh can source this file for its port
# resolution functions without also running whatever action $1 says.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
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
		is_running && die "already running (pid $(qemu_pid)) — stop it first: $0 stop"
		printf 'installing\n' > "$PHASE"
		rm -f "$STAMP"
		launch cdrom
		printf "\n  ${C_BOLD}Unattended install running.${C_RESET} ${C_DIM}What follows is the installer's own log,\n"
		printf "  read off its serial port. Ctrl+C detaches; re-attach with: %s watch${C_RESET}\n\n" "$0"
		# finish-install writes B2B-INSTALL-COMPLETE to ttyS0, then d-i halts.
		if ! watch_install; then
			printf "    ${C_DIM}The VM is left running for a look. Stop it with: %s stop${C_RESET}\n" "$0"
			die "the install did not finish"
		fi
		# The marker is written by the second-to-last hook, so d-i still has
		# 95umount to run. Give it that, then take the machine down: it ends
		# on `halt`, and a halted kernel does not answer the ACPI power
		# button, so SIGTERM is the normal end of this sequence -- not a
		# failure. Bounded at ~70s instead of the 5 minutes this used to wait.
		if is_running; then
			info "letting the installer unmount and halt"
			for _ in $(seq 1 15); do is_running || break; sleep 2; done
			if is_running; then
				mon "system_powerdown" > /dev/null
				for _ in $(seq 1 10); do is_running || break; sleep 2; done
			fi
			if is_running; then
				info "the guest is halted (it ignores ACPI) — stopping QEMU"
				kill "$(qemu_pid)" 2> /dev/null; sleep 2
				kill -9 "$(qemu_pid)" 2> /dev/null
			fi
		fi
		rm -f "$MONITOR"
		rm -f "$PIDFILE"
		date '+%Y-%m-%d %H:%M:%S' > "$STAMP"
		rm -f "$PHASE"
		ok "install phase done — boot it with: $0 start"
		;;

	start)
		# A running QEMU is not necessarily the installed system booting: it
		# may still be d-i owning the disk, and typing a LUKS passphrase at
		# the installer is 45 seconds of nothing followed by a wrong diagnosis.
		if is_running && [ "$(cat "$PHASE" 2> /dev/null)" = installing ]; then
			printf "  ${C_RED}✗${C_RESET} the installer is still running in this VM (pid %s)\n" "$(qemu_pid)" >&2
			die "re-attach to it with: $0 watch   (or stop it: $0 stop)"
		fi
		# .phase still says "installing" with no QEMU behind it: the install
		# was interrupted (Ctrl+C, a crash, a stall). Whatever is on the disk
		# is half of a system; booting it would sit at a broken GRUB or an
		# initramfs prompt and then be blamed on the LUKS unlock.
		if ! is_running && [ "$(cat "$PHASE" 2> /dev/null)" = installing ]; then
			die "the last install of this disk was interrupted — run it again: $0 install"
		fi
		if ! is_running && [ ! -f "$STAMP" ] \
			&& [ "$(stat -c %s "$DISK" 2> /dev/null || echo 0)" -le 1073741824 ]; then
			die "nothing is installed on this disk yet — run: $0 install"
		fi
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
		ssh_port=$(host_port_of ssh)

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
		if ! is_running; then
			report_other_guests && exit 1
			ok "not running"; exit 0
		fi
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
		if ! p=$(qemu_pid); then
			report_other_guests && exit 1
			ok "not running"; exit 0
		fi
		kill "$p" 2> /dev/null; sleep 2; kill -9 "$p" 2> /dev/null
		rm -f "$PIDFILE" "$MONITOR"
		ok "killed"
		;;

	watch)
		is_running || die "nothing is running for $VM_NAME"
		watch_install
		;;
	console)
		[ -f "$SERIAL" ] || die "no serial log yet"
		printf "  ${C_DIM}Ctrl+C stops watching, not the VM${C_RESET}\n\n"
		tail -f "$SERIAL"
		;;

	ssh-config)
		ssh_port=$(host_port_of ssh)
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
		printf "  %-12s %s\n" "KVM now:" "$(kvm_why)"
		if [ -f "$STAMP" ]; then printf "  %-12s installed %s\n" "system:" "$(cat "$STAMP")"
		elif [ "$(cat "$PHASE" 2> /dev/null)" = installing ]; then printf "  %-12s install in progress (or interrupted)\n" "system:"
		else printf "  %-12s nothing installed yet\n" "system:"; fi
		if is_running && guest_halted; then
			printf "  %-12s ${C_YELLOW}halted${C_RESET} (pid %s — stopped itself; QEMU is still up)\n" \
				"state:" "$(qemu_pid)"
		elif is_running; then
			printf "  %-12s ${C_GREEN}running${C_RESET} (pid %s)\n" "state:" "$(qemu_pid)"
		else
			printf "  %-12s stopped\n" "state:"
		fi
		others=$(other_guests)
		[ -n "$others" ] && printf "  %-12s ${C_YELLOW}%s${C_RESET}\n" "elsewhere:" \
			"$(printf '%s\n' "$others" | awk '{printf "pid %s (VM_PATH=%s) ", $1, $2}')"
		[ -f "$DISK" ] && printf "  %-12s %s (%s on host)\n" "disk:" "$DISK" "$(du -h "$DISK" 2>/dev/null | cut -f1)"
		printf "  %-12s %s\n" "iso:" "$(basename "$(find_iso)" 2>/dev/null || echo none)"
		printf "  %-12s " "ports:"
		for _spec in $PORTS_SPEC; do
			_n="${_spec%%:*}"; _rest="${_spec#*:}"; _gp="${_rest#*:}"
			printf '%s→%s ' "$(host_port_of "$_n")" "$_gp"
		done
		printf "\n"
		if [ -f "$SERIAL" ]; then
			printf "  %-12s %s\n" "console:" "$(tail -c 400 "$SERIAL" 2>/dev/null | tr -d '\r' | grep -a . | tail -1 | cut -c1-70)"
		fi
		printf "\n"
		;;

	*) die "unknown action '${1}' (create|install|start|unlock|stop|kill|status|console|screenshot|ssh-config)" ;;
esac
fi
