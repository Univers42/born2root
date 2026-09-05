#!/bin/bash

## ARCHITECTURE MODULE
architecture_module() {
    register_metric "architecture"

    # Method 1: Using uname
    get_arch_uname() {
        if command -v uname &>/dev/null; then
            local arch
            arch=$(uname -m)
            if [ -n "$arch" ]; then
                echo "$arch"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 2: Using arch command
    get_arch_command() {
        if command -v arch &>/dev/null; then
            local arch
            arch=$(arch 2>/dev/null)
            if [ -n "$arch" ]; then
                echo "$arch"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 3: Using dpkg for Debian-based systems
    get_arch_dpkg() {
        if command -v dpkg &>/dev/null; then
            local arch
            arch=$(dpkg --print-architecture 2>/dev/null)
            if [ -n "$arch" ]; then
                echo "$arch"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 4: Using /proc/cpuinfo
    get_arch_cpuinfo() {
        if [ -f /proc/cpuinfo ]; then
            local arch
            arch=$(grep -m1 "model name\|^vendor_id\|^machine" /proc/cpuinfo 2>/dev/null)
            if [ -n "$arch" ]; then
                echo "$arch" | sed 's/.*: //'
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Run all methods
    arch_uname=$(get_arch_uname)
    arch_command=$(get_arch_command)
    arch_dpkg=$(get_arch_dpkg)
    arch_cpuinfo=$(get_arch_cpuinfo)

    log_debug "Architecture Detection Methods:"
    log_debug "  uname: $arch_uname"
    log_debug "  arch command: $arch_command"
    log_debug "  dpkg: $arch_dpkg"
    log_debug "  cpuinfo: $arch_cpuinfo"

    # For architecture, we'll mostly just check if we get a consistent result
    # Use uname as the primary method since it's most commonly available
    if [ "$arch_uname" != "N/A" ]; then
        update_metric_state "architecture" $STATE_OK "$arch_uname" "Using uname as primary method"
    else
        # Fall back to the first available method
        for method in "$arch_command" "$arch_dpkg" "$arch_cpuinfo"; do
            if [ "$method" != "N/A" ]; then
                update_metric_state "architecture" $STATE_OK "$method" "Using fallback method"
                break
            fi
        done

        if [ "${METRIC_VALUES[architecture]}" = "" ]; then
            update_metric_state "architecture" $STATE_ERROR "N/A" "All architecture detection methods failed"
        fi
    fi
}
