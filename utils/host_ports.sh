#!/bin/bash
# Host TCP port allocation for the VirtualBox NAT port-forward rules.
#
# Sourced by setup/install/vms/install_vm_debian.sh (which creates the rules) and
# generate/orchestrate.sh (which repairs them on later runs). Both build the same
# set of rules, so the allocator lives here once instead of once per caller.

RESERVED_HOST_PORTS=""

is_host_port_reserved() {
    case " $RESERVED_HOST_PORTS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
    esac
}

reserve_host_port() {
    RESERVED_HOST_PORTS="${RESERVED_HOST_PORTS} $1"
}

# Is nothing listening on this TCP port on the host?
#
# Portability: `ss` is Linux/iproute2 only and `netstat -tln` is Linux syntax that
# BSD/macOS netstat rejects, so probe in order of availability and finish with a
# plain connect. `netstat -an` is the one spelling Linux, macOS and Git Bash all
# accept; its local-address column is host:port on Linux/Windows but host.port on
# BSD, hence the [:.] separator class.
is_host_port_free() {
    local port="$1"
    [ -n "$port" ] || return 1

    if command -v ss >/dev/null 2>&1; then
        if ss -H -ltn 2>/dev/null |
            awk -v p="$port" '$4 ~ ("[:.]" p "$") { found = 1 } END { exit found ? 0 : 1 }'; then
            return 1 # something already listens there
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        # Scan every column rather than a fixed one: the local address is $4 on
        # Linux/BSD but $2 on Windows, whose output is indented. On a listening
        # row the peer column is always *.*, 0.0.0.0:* or 0.0.0.0:0, so it can
        # never collide with a port we ask about.
        if netstat -an 2>/dev/null | awk -v p="$port" '
			tolower($0) ~ /listen/ {
				for (i = 1; i <= NF; i++)
					if ($i ~ ("[:.]" p "$"))
						found = 1
			}
			END { exit found ? 0 : 1 }'; then
            return 1
        fi
    fi

    if command -v nc >/dev/null 2>&1 && nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
        return 1 # port answers on loopback
    fi
    return 0
}

# resolve_host_port <varname> <preferred_port>
#
# Assign the first free host port at or above <preferred_port> to <varname> and
# reserve it for the rest of this run.
#
# It assigns through a caller-named variable instead of echoing its result
# because the reservation has to survive the call: `p=$(resolve_host_port ...)`
# runs the function in a subshell and throws RESERVED_HOST_PORTS away, so every
# service whose preferred port was busy walks to the same next-free port.
# VirtualBox then rejects the second rule claiming it, with
# "A NAT rule for this host port and this host IP already exists".
resolve_host_port() {
    local __rhp_var="$1" port="$2" i=0

    while [ "$i" -lt 100 ]; do
        if ! is_host_port_reserved "$port" && is_host_port_free "$port"; then
            reserve_host_port "$port"
            printf -v "$__rhp_var" '%s' "$port"
            return 0
        fi
        port=$((port + 1))
        i=$((i + 1))
    done

    echo "Error: no free host port in ${2}-$((${2} + 99))" >&2
    return 1
}
