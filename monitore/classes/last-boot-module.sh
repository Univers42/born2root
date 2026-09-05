#!/bin/bash

## LAST BOOT MODULE
last_boot_module() {
    register_metric "last_boot"

    # Format the boot time consistently
    format_boot_time() {
        local input="$1"
        # Try to convert to consistent format if possible
        date -d "$input" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$input"
    }

    # Method 1: Using who command
    get_boot_who() {
        if command -v who &>/dev/null; then
            local who_output boot_time
            who_output=$(who -b 2>/dev/null)
            if [ -n "$who_output" ]; then
                boot_time=$(echo "$who_output" | awk '{print $3 " " $4}')
                if [ -n "$boot_time" ]; then
                    format_boot_time "$boot_time"
                else
                    echo "N/A"
                fi
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 2: Using last reboot command
    get_boot_last() {
        if command -v last &>/dev/null; then
            local boot_info boot_time
            boot_info=$(last reboot 2>/dev/null | head -1)
            if [[ -n "$boot_info" && "$boot_info" != *"wtmp begins"* ]]; then
                boot_time=$(echo "$boot_info" | awk '{print $5 " " $6 " " $7 " " $8}')
                if [ -n "$boot_time" ]; then
                    format_boot_time "$boot_time"
                else
                    echo "N/A"
                fi
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 3: Using uptime -s
    get_boot_uptime() {
        if command -v uptime &>/dev/null && uptime -s &>/dev/null; then
            local uptime_output
            uptime_output=$(uptime -s 2>/dev/null)
            if [ -n "$uptime_output" ]; then
                echo "$uptime_output"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 4: Using /proc/uptime
    get_boot_proc() {
        if [[ -f /proc/uptime ]]; then
            local current_time uptime_seconds boot_time
            current_time=$(date +%s)
            uptime_seconds=$(cat /proc/uptime 2>/dev/null | awk '{print $1}' | cut -d. -f1)
            if [ -n "$uptime_seconds" ]; then
                boot_time=$((current_time - uptime_seconds))
                date -d "@$boot_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "N/A"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Run all methods
    boot_who=$(get_boot_who)
    boot_last=$(get_boot_last)
    boot_uptime=$(get_boot_uptime)
    boot_proc=$(get_boot_proc)

    log_debug "Last Boot Methods:"
    log_debug "  who -b: $boot_who"
    log_debug "  last reboot: $boot_last"
    log_debug "  uptime -s: $boot_uptime"
    log_debug "  /proc/uptime: $boot_proc"

    # For boot time, do string verification after normalizing dates
    # But we'll just use the first available method for now
    for method in "$boot_who" "$boot_uptime" "$boot_proc" "$boot_last"; do
        if [ "$method" != "N/A" ]; then
            update_metric_state "last_boot" $STATE_OK "$method" "Using first available method"
            break
        fi
    done

    if [ "${METRIC_VALUES[last_boot]}" = "" ]; then
        update_metric_state "last_boot" $STATE_ERROR "N/A" "All boot time methods failed"
    fi
}
