#!/bin/bash

## MEMORY USAGE MODULE
memory_module() {
    register_metric "memory"

    # Method 1: Using free command
    get_memory_free() {
        if command -v free &>/dev/null; then
            local total used percent
            total=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')
            used=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}')
            if [ -n "$total" ] && [ -n "$used" ] && [ "$total" -gt 0 ]; then
                percent=$(awk "BEGIN {printf \"%.2f\", $used*100/$total}")
                echo "$used/$total MB ($percent%)"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 2: Using /proc/meminfo
    get_memory_proc() {
        if [ -f /proc/meminfo ]; then
            local total avail used percent
            total=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2/1024}' | cut -d. -f1)
            avail=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2/1024}' | cut -d. -f1)
            if [ -n "$total" ] && [ -n "$avail" ] && [ "$total" -gt 0 ]; then
                used=$((total - avail))
                percent=$(awk "BEGIN {printf \"%.2f\", $used*100/$total}")
                echo "$used/$total MB ($percent%)"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 3: Using vmstat
    get_memory_vmstat() {
        if command -v vmstat &>/dev/null; then
            local total used free percent
            total=$(vmstat -s 2>/dev/null | grep "total memory" | awk '{print $1/1024}' | cut -d. -f1)
            # Some versions of vmstat use 'used memory' and 'free memory'
            used=$(vmstat -s 2>/dev/null | grep "used memory" | awk '{print $1/1024}' | cut -d. -f1)
            free=$(vmstat -s 2>/dev/null | grep "free memory" | awk '{print $1/1024}' | cut -d. -f1)
            if [ -n "$total" ] && [ -n "$used" ] && [ "$total" -gt 0 ]; then
                percent=$(awk "BEGIN {printf \"%.2f\", $used*100/$total}")
                echo "$used/$total MB ($percent%)"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 4: Using top in batch mode
    get_memory_top() {
        if command -v top &>/dev/null; then
            local mem_line total used percent
            mem_line=$(top -b -n 1 2>/dev/null | grep "MiB Mem")
            if [ -n "$mem_line" ]; then
                total=$(echo "$mem_line" | awk '{print $4}' | cut -d. -f1)
                used=$(echo "$mem_line" | awk '{print $6}' | cut -d. -f1)
                if [[ -n "$total" && -n "$used" && "$total" -gt 0 ]]; then
                    percent=$(awk "BEGIN {printf \"%.2f\", $used*100/$total}")
                    echo "$used/$total MB ($percent%)"
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

    # Run all methods
    mem_free=$(get_memory_free)
    mem_proc=$(get_memory_proc)
    mem_vmstat=$(get_memory_vmstat)
    mem_top=$(get_memory_top)

    log_debug "Memory Usage Methods:"
    log_debug "  free: $mem_free"
    log_debug "  /proc/meminfo: $mem_proc"
    log_debug "  vmstat: $mem_vmstat"
    log_debug "  top: $mem_top"

    # Extract percentages for verification
    extract_percent() {
        echo "$1" | grep -o '[0-9]*\.[0-9]*%\|[0-9]*%' | sed 's/%//' | head -1
    }

    free_percent=$(extract_percent "$mem_free")
    proc_percent=$(extract_percent "$mem_proc")
    vmstat_percent=$(extract_percent "$mem_vmstat")
    top_percent=$(extract_percent "$mem_top")

    # Verify the percentages
    verify_values "memory_percent" "$free_percent" "$proc_percent" "$vmstat_percent" "$top_percent"

    # Use the primary method (free) for the actual value
    if [ "$mem_free" != "N/A" ]; then
        update_metric_state "memory" "${METRIC_STATES[memory_percent]}" "$mem_free" "${METRIC_MESSAGES[memory_percent]}"
    else
        # Fall back to the first available method
        for method in "$mem_proc" "$mem_vmstat" "$mem_top"; do
            if [ "$method" != "N/A" ]; then
                update_metric_state "memory" "${METRIC_STATES[memory_percent]}" "$method" "Using fallback method"
                break
            fi
        done

        if [ "${METRIC_VALUES[memory]}" = "" ]; then
            update_metric_state "memory" $STATE_ERROR "N/A" "All memory methods failed"
        fi
    fi
}
