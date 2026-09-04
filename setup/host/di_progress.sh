#!/usr/bin/env bash
# ============================================================================ #
#  di_progress.sh — read the Debian installer's progress off the serial log    #
# ============================================================================ #
#
# Sourced by qemu_vm.sh and generate/orchestrate.sh, not run. Provides:
#
#   di_stage_label <menu-item>       'partman-base' -> 'Partitioning the disk (LUKS + LVM)'
#   di_current_stage <serial.log>    label of the last d-i menu item selected
#   di_last_activity <serial.log>    the installer's most recent line, trimmed
#   di_failed_step <serial.log>      what d-i said failed, if anything did
#   di_install_complete <serial.log> the finish-install marker, on its own line
#   di_reached_final_unmount <log>   d-i started 95umount, its last hook
#
# WHERE THE LINES COME FROM
#   preseeds/preseed.cfg's early_command starts a job inside the installer that
#   copies its own /var/log/syslog to /dev/ttyS0, minus the kernel's lines.
#   That is not the same as booting d-i on a serial console -- which makes it
#   wrap itself in GNU screen and stall (generate/create_custom_iso.sh) -- it
#   is plain text written to a device while d-i's UI stays on the VGA screen.
#   Both hypervisors spool ttyS0 into disk_images/<vm>/serial.log, so one
#   parser serves both dashboards.
#
# WHAT THE LINES LOOK LIKE (busybox syslogd -S: timestamp, tag, message)
#   Sep  4 14:01:12 main-menu[315]: INFO: Menu item 'partman-base' selected
#   Sep  4 14:03:40 main-menu[315]: WARNING **: Configuring 'partman-base' failed with error code 1
#   Sep  4 14:03:40 main-menu[315]: WARNING **: Menu item 'partman-base' failed.
#   Sep  4 14:05:02 debootstrap: Extracting libc6...
#   Sep  4 14:12:33 in-target: Setting up docker-ce (5:28.0.1-1~debian.13~trixie) ...
#   B2B-INSTALL-COMPLETE        <- written by 99b2b-serial-marker, own line
#
# A failed step is final: at priority=critical d-i then shows "Installation
# step failed" and waits for a keypress that will never come.
#
# Nothing here pipes into `grep -q`: these scripts run with pipefail, and a
# grep -q that exits early hands its writer SIGPIPE, which pipefail reports
# as failure (that exact bug once made select_backend.sh call a loaded
# VirtualBox driver "not loaded").
# ============================================================================ #

di_stage_label() {
	case "$1" in
		localechooser)                 printf 'Choosing language and locale' ;;
		console-setup-udeb|kbd-chooser) printf 'Configuring the keyboard' ;;
		cdrom-detect|load-cdrom)       printf 'Mounting the installation media' ;;
		ethdetect)                     printf 'Detecting network hardware' ;;
		netcfg)                        printf 'Configuring the network (DHCP)' ;;
		choose-mirror)                 printf 'Choosing a Debian mirror' ;;
		download-installer|load-install|anna) printf 'Loading installer components' ;;
		hw-detect)                     printf 'Detecting hardware' ;;
		clock-setup)                   printf 'Setting the clock (NTP)' ;;
		disk-detect)                   printf 'Detecting disks' ;;
		partman-base)                  printf 'Partitioning the disk (LUKS + LVM)' ;;
		bootstrap-base)                printf 'Installing the base system' ;;
		user-setup-udeb)               printf 'Creating users' ;;
		apt-setup-udeb)                printf 'Configuring apt' ;;
		pkgsel)                        printf 'Installing packages (tasksel)' ;;
		grub-installer)                printf 'Installing GRUB' ;;
		finish-install)                printf 'Finishing: late_command runs b2b-setup.sh' ;;
		*)                             printf 'Running %s' "$1" ;;
	esac
}

# Strip "Sep  4 14:01:12 ", a "[pid]", and the literal "^M" busybox syslogd
# writes where apt sent a carriage return, so what is left reads as a sentence.
_di_clean() { tr -d '\r' | sed -E 's/^[A-Z][a-z]{2} +[0-9]+ [0-9:]{8} //; s/\[[0-9]+\]://; s/(\^M)+$//'; }

di_current_stage() {
	local log="$1" item
	[ -n "$log" ] && [ -r "$log" ] || return 1
	item=$(tr -d '\r' < "$log" \
		| sed -n "s/.*main-menu\[[0-9]*\]: INFO: Menu item '\([^']*\)' selected.*/\1/p" \
		| tail -n 1)
	[ -n "$item" ] || return 1
	di_stage_label "$item"
}

di_last_activity() {
	local log="$1" line
	[ -n "$log" ] && [ -r "$log" ] || return 1
	line=$(tail -n 1 "$log" 2> /dev/null | _di_clean)
	[ -n "$line" ] || return 1
	printf '%s' "$line"
}

di_failed_step() {
	local log="$1" line
	[ -n "$log" ] && [ -r "$log" ] || return 1
	line=$(tr -d '\r' < "$log" \
		| grep -oE "Configuring '[^']+' failed with error code [0-9]+|Menu item '[^']+' failed" \
		| tail -n 1)
	[ -n "$line" ] || return 1
	printf '%s' "$line"
}

# Does a line read like the reason an install stopped? Used only together
# with silence: a healthy install never sits still for minutes right after
# one of these, but it does log benign warnings all the time ("WARNING **:
# Started DHCP client", "warning: Unable to find contrib/.../Packages"), so
# those words are deliberately NOT in this list.
di_looks_like_error() {
	[[ "${1,,}" =~ (too small|fail|error|cannot|no space left|not found|denied|timed out|unreachable) ]]
}

# Anchored at the line start on purpose. d-i logs the late_command's TEXT when
# it starts it, and that text contains this string; the feed drops those lines
# too, but a stray match here would end the install ten minutes early.
di_install_complete() {
	[ -n "$1" ] && [ -r "$1" ] && grep -q '^B2B-INSTALL-COMPLETE' "$1" 2> /dev/null
}

# 95umount is the last hook d-i runs, and it unmounts /dev -- which is why
# nothing after it can log or write to the serial port (see preseeds/preseed.cfg).
# Reaching it means every step that installs anything has already finished.
di_reached_final_unmount() {
	[ -n "$1" ] && [ -r "$1" ] \
		&& grep -q 'finish-install\.d/95umount' "$1" 2> /dev/null
}
