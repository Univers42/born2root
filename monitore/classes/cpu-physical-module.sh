#!/bin/bash

## CPU PHYSICAL MODULE
cpu_physical_module() {
    register_metric "cpu_physical"

    # Get CPU counts using different methods
    physical_cpu1=$(grep "physical id" /proc/cpuinfo 2>/dev/null | sort -u | wc -l)
    if [ -z "$physical_cpu1" ] || [ "$physical_cpu1" -eq 0 ]; then
        physical_cpu1="N/A"
    fi

    if command -v lscpu &>/dev/null; then
        physical_cpu2=$(lscpu 2>/dev/null | awk '/Socket\(s\):/ {print $2}')
        if [ -z "$physical_cpu2" ] || [ "$physical_cpu2" -eq 0 ]; then
            physical_cpu2="N/A"
        fi
    else
        physical_cpu2="N/A"
    fi

    physical_cpu3=$(grep "physical id" /proc/cpuinfo 2>/dev/null | sort -u | wc -l)
    if [ -z "$physical_cpu3" ] || [ "$physical_cpu3" -eq 0 ]; then
        physical_cpu3="N/A"
    fi

    physical_cpu4=$(cat /sys/devices/system/cpu/cpu*/topology/physical_package_id 2>/dev/null | sort -u | wc -l)
    if [ -z "$physical_cpu4" ] || [ "$physical_cpu4" -eq 0 ]; then
        physical_cpu4="N/A"
    fi

    log_debug "Physical CPU Count Methods:"
    log_debug "  /proc/cpuinfo (1): $physical_cpu1"
    log_debug "  lscpu: $physical_cpu2"
    log_debug "  /proc/cpuinfo (2): $physical_cpu3"
    log_debug "  /sys: $physical_cpu4"

    # Verify all methods
    verify_values "cpu_physical" "$physical_cpu1" "$physical_cpu2" "$physical_cpu3" "$physical_cpu4"
}
