#!/bin/bash

## CPU CORE COUNT MODULE
cpu_core_module() {
    register_metric "cpu_core"

    # Multiple methods for CPU core count
    cpu_count_nproc=$(nproc 2>/dev/null)
    if [ -z "$cpu_count_nproc" ] || [ "$cpu_count_nproc" -eq 0 ]; then
        cpu_count_nproc="N/A"
    fi

    cpu_count_proc=$(grep -c processor /proc/cpuinfo 2>/dev/null)
    if [ -z "$cpu_count_proc" ] || [ "$cpu_count_proc" -eq 0 ]; then
        cpu_count_proc="N/A"
    fi

    if command -v lscpu &>/dev/null; then
        lscpu_filter=$(lscpu 2>/dev/null | awk '/^CPU\(s\)/ {print $2}')
        if [ -z "$lscpu_filter" ] || [ "$lscpu_filter" -eq 0 ]; then
            lscpu_filter="N/A"
        fi
    else
        lscpu_filter="N/A"
    fi

    if command -v getconf &>/dev/null; then
        getconf_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
        if [ -z "$getconf_count" ] || [ "$getconf_count" -eq 0 ]; then
            getconf_count="N/A"
        fi
    else
        getconf_count="N/A"
    fi

    sys_cpu_count=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)
    if [ -z "$sys_cpu_count" ] || [ "$sys_cpu_count" -eq 0 ]; then
        sys_cpu_count="N/A"
    fi

    if [ -f /sys/devices/system/cpu/present ]; then
        present_count=$(cat /sys/devices/system/cpu/present 2>/dev/null | awk -F- '{print $2+1}')
        if [ -z "$present_count" ] || [ "$present_count" -eq 0 ]; then
            present_count="N/A"
        fi
    else
        present_count="N/A"
    fi

    log_debug "CPU Core Count Methods:"
    log_debug "  nproc: $cpu_count_nproc"
    log_debug "  /proc/cpuinfo: $cpu_count_proc"
    log_debug "  lscpu: $lscpu_filter"
    log_debug "  getconf: $getconf_count"
    log_debug "  sys count: $sys_cpu_count"
    log_debug "  present: $present_count"

    # Verify all methods
    verify_values "cpu_core" "$cpu_count_nproc" "$cpu_count_proc" "$lscpu_filter" "$getconf_count" "$sys_cpu_count" "$present_count"
}
