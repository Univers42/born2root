#!/bin/bash

## CPU LOAD MODULE
cpu_load_module() {
    register_metric "cpu_load"

    # Function to format a number with a specific precision
    format_number() {
        # Use 2 decimal places for more precision
        printf "%.2f" "$1" 2>/dev/null || echo "$1"
    }

    # Method 1: Using top
    get_cpu_top() {
        if command -v top &>/dev/null; then
            local top_output cpu_usage
            top_output=$(top -bn2 2>/dev/null | grep "Cpu(s)" | tail -1)
            if [ -n "$top_output" ]; then
                # Extract both user and system CPU time
                cpu_usage=$(echo "$top_output" | awk '{print $2 + $4 + $6}')
                if [ -n "$cpu_usage" ]; then
                    # Ensure we don't report exactly 0.0
                    if (($(echo "$cpu_usage < 0.01" | bc -l))); then
                        cpu_usage="0.01"
                    fi
                    echo "$(format_number $cpu_usage)%"
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

    # Method 2: Using /proc/stat (more accurate)
    get_cpu_proc() {
        if [ -f /proc/stat ]; then
            # Take two samples with a slightly longer interval for better accuracy
            local stat1 stat2
            stat1=$(cat /proc/stat 2>/dev/null | grep '^cpu ')
            sleep 0.5
            stat2=$(cat /proc/stat 2>/dev/null | grep '^cpu ')

            if [[ -n "$stat1" && -n "$stat2" ]]; then
                # Parse the stats
                local cpu1=($stat1)
                local cpu2=($stat2)

                # Calculate total CPU time for each sample (include all fields)
                local total1=0
                local total2=0
                for i in {1..10}; do
                    if [[ -n "${cpu1[$i]}" ]]; then
                        total1=$((total1 + ${cpu1[$i]}))
                    fi
                    if [[ -n "${cpu2[$i]}" ]]; then
                        total2=$((total2 + ${cpu2[$i]}))
                    fi
                done

                # Calculate idle CPU time for each sample
                local idle1=${cpu1[4]}
                local idle2=${cpu2[4]}

                # Calculate total and idle time difference
                local totald idled cpu_usage
                totald=$((total2 - total1))
                idled=$((idle2 - idle1))

                if [ $totald -gt 0 ]; then
                    # Calculate CPU usage percentage
                    cpu_usage=$(awk "BEGIN {print (1 - $idled/$totald) * 100}")
                    # Ensure we don't report exactly 0.0
                    if (($(echo "$cpu_usage < 0.01" | bc -l))); then
                        cpu_usage="0.01"
                    fi
                    echo "$(format_number $cpu_usage)%"
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

    # Method 3: Using mpstat if available
    get_cpu_mpstat() {
        if command -v mpstat &>/dev/null; then
            # Use a longer sampling time for better accuracy
            local mpstat_output cpu_usage
            mpstat_output=$(mpstat 1 2 2>/dev/null)
            if [ -n "$mpstat_output" ]; then
                cpu_usage=$(echo "$mpstat_output" | grep "Average.*all" | awk '{print 100 - $NF}')
                if [ -n "$cpu_usage" ]; then
                    # Ensure we don't report exactly 0.0
                    if (($(echo "$cpu_usage < 0.01" | bc -l))); then
                        cpu_usage="0.01"
                    fi
                    echo "$(format_number $cpu_usage)%"
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

    # Method 4: Using vmstat with multiple samples
    get_cpu_vmstat() {
        if command -v vmstat &>/dev/null; then
            # Take 3 samples over 2 seconds for better accuracy
            local vmstat_output cpu_idle cpu_usage
            vmstat_output=$(vmstat 1 3 2>/dev/null | tail -1)
            if [ -n "$vmstat_output" ]; then
                cpu_idle=$(echo "$vmstat_output" | awk '{print $15}')
                if [ -n "$cpu_idle" ]; then
                    cpu_usage=$(awk "BEGIN {print 100 - $cpu_idle}")
                    # Ensure we don't report exactly 0.0
                    if (($(echo "$cpu_usage < 0.01" | bc -l))); then
                        cpu_usage="0.01"
                    fi
                    echo "$(format_number $cpu_usage)%"
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

    # Method 5: Using uptime load average
    get_cpu_uptime() {
        if command -v uptime &>/dev/null; then
            local uptime_output load cpu_usage
            uptime_output=$(uptime 2>/dev/null)
            if [ -n "$uptime_output" ]; then
                # Get 1-minute load average and convert to percentage
                load=$(echo "$uptime_output" | awk -F'[a-z]:' '{print $2}' | awk '{print $1}' | tr -d ',')
                if [ -n "$load" ]; then
                    # Get CPU core count to normalize load average
                    local cores=1
                    if [ -n "${METRIC_VALUES[cpu_core]}" ] && [[ "${METRIC_VALUES[cpu_core]}" =~ ^[0-9]+$ ]]; then
                        cores=${METRIC_VALUES[cpu_core]}
                    elif command -v nproc &>/dev/null; then
                        cores=$(nproc 2>/dev/null || echo 1)
                    fi

                    # Convert load to percentage (load/cores * 100)
                    cpu_usage=$(awk "BEGIN {print ($load/$cores) * 100}")
                    # Ensure we don't report exactly 0.0
                    if (($(echo "$cpu_usage < 0.01" | bc -l))); then
                        cpu_usage="0.01"
                    fi
                    echo "$(format_number $cpu_usage)%"
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
    cpu_top=$(get_cpu_top)
    cpu_proc=$(get_cpu_proc)
    cpu_mpstat=$(get_cpu_mpstat)
    cpu_vmstat=$(get_cpu_vmstat)
    cpu_uptime=$(get_cpu_uptime)

    log_debug "CPU Load Methods (raw values):"
    log_debug "  top: $cpu_top"
    log_debug "  proc/stat: $cpu_proc"
    log_debug "  mpstat: $cpu_mpstat"
    log_debug "  vmstat: $cpu_vmstat"
    log_debug "  uptime: $cpu_uptime"

    # Extract percentages for verification
    extract_percent() {
        echo "$1" | grep -o '[0-9]*\.[0-9]*%\|[0-9]*%' | sed 's/%//' | head -1
    }

    top_percent=$(extract_percent "$cpu_top")
    proc_percent=$(extract_percent "$cpu_proc")
    mpstat_percent=$(extract_percent "$cpu_mpstat")
    vmstat_percent=$(extract_percent "$cpu_vmstat")
    uptime_percent=$(extract_percent "$cpu_uptime")

    # Verify the percentages
    verify_values "cpu_load" "$top_percent" "$proc_percent" "$mpstat_percent" "$vmstat_percent" "$uptime_percent"

    # Load average as additional info (not verified)
    if [ -f /proc/loadavg ]; then
        load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1", "$2", "$3}')
        METRIC_VALUES["load_avg"]="$load_avg"
    else
        METRIC_VALUES["load_avg"]="N/A"
    fi
}
