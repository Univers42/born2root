#!/bin/bash

## DISK USAGE MODULE
disk_module() {
    register_metric "disk"

    # Method 1: Using df
    get_disk_df() {
        if command -v df &>/dev/null; then
            local df_output
            df_output=$(df -h --total 2>/dev/null | grep total)
            if [ -n "$df_output" ]; then
                echo "$(echo "$df_output" | awk '{print $3"/"$2" ("$5")"}')"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 2: Using lsblk for mounted partitions
    get_disk_lsblk() {
        if command -v lsblk &>/dev/null; then
            # Filter out problematic characters and device types
            # Using more specific output format to avoid tree characters and focus on needed columns
            local usage_data
            usage_data=$(lsblk -b -o NAME,SIZE,FSUSE%,MOUNTPOINT 2>/dev/null |
                grep -v "^loop" |
                sed '/^$/d' |
                grep -v " $" |
                grep -v '[-`│├└┬┼─]' |
                grep "[0-9]")

            if [ -n "$usage_data" ]; then
                local total_size=0
                local used_size=0

                while read -r line; do
                    if [[ -n $line && $line != *"[SWAP]"* ]]; then
                        # Extract values more carefully
                        local size use_percent
                        size=$(echo "$line" | awk '{print $2}')
                        use_percent=$(echo "$line" | awk '{print $3}' | tr -d '%')

                        # Validate the extracted values
                        if [[ -n "$size" && "$size" =~ ^[0-9]+$ && "$size" != "0" && -n "$use_percent" && "$use_percent" =~ ^[0-9.]+$ ]]; then
                            total_size=$((total_size + size))
                            used_size=$(awk "BEGIN {print $used_size + ($size * $use_percent / 100)}")
                        fi
                    fi
                done <<<"$usage_data"

                if [[ $total_size -gt 0 ]]; then
                    # Convert to human readable
                    local total_human used_human use_percent
                    total_human=$(numfmt --to=iec --suffix=B $total_size 2>/dev/null || echo "$(($total_size / 1073741824))GB")
                    used_human=$(numfmt --to=iec --suffix=B ${used_size%.*} 2>/dev/null || echo "$((${used_size%.*} / 1073741824))GB")
                    use_percent=$(awk "BEGIN {printf \"%.1f%%\", ($total_size>0) ? $used_size*100/$total_size : 0}")

                    echo "$used_human/$total_human ($use_percent)"
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

    # Method 3: Using findmnt with improved filtering
    get_disk_findmnt() {
        if command -v findmnt &>/dev/null; then
            # We'll use a more focused approach with findmnt to avoid special characters
            local mounts
            mounts=$(findmnt -t ext4,xfs,btrfs,vfat,fat,ntfs -o TARGET,SIZE,USED -b -n 2>/dev/null |
                grep -v "^/$" |
                grep "[0-9]")

            if [ -n "$mounts" ]; then
                local total=0
                local used=0

                while read -r mount; do
                    if [[ -n $mount ]]; then
                        local mount_size mount_used
                        mount_size=$(echo "$mount" | awk '{print $2}')
                        mount_used=$(echo "$mount" | awk '{print $3}')

                        # Validate the values before using them
                        if [[ -n "$mount_size" && "$mount_size" =~ ^[0-9]+$ && -n "$mount_used" && "$mount_used" =~ ^[0-9]+$ ]]; then
                            total=$((total + mount_size))
                            used=$((used + mount_used))
                        fi
                    fi
                done <<<"$mounts"

                if [[ $total -gt 0 ]]; then
                    # Convert to human readable
                    local total_human used_human use_percent
                    total_human=$(numfmt --to=iec --suffix=B $total 2>/dev/null || echo "$(($total / 1073741824))GB")
                    used_human=$(numfmt --to=iec --suffix=B $used 2>/dev/null || echo "$(($used / 1073741824))GB")
                    use_percent=$(awk "BEGIN {printf \"%.1f%%\", ($total>0) ? $used*100/$total : 0}")

                    echo "$used_human/$total_human ($use_percent)"
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
    disk_df=$(get_disk_df)
    disk_lsblk=$(get_disk_lsblk)
    disk_findmnt=$(get_disk_findmnt)

    log_debug "Disk Usage Methods:"
    log_debug "  df: $disk_df"
    log_debug "  lsblk: $disk_lsblk"
    log_debug "  findmnt: $disk_findmnt"

    # Extract percentages for verification with improved safety
    extract_percent() {
        local value="$1"
        if [ -z "$value" ] || [ "$value" = "N/A" ]; then
            echo "N/A"
            return
        fi
        local percent
        percent=$(echo "$value" | grep -o '[0-9]*\.[0-9]*%\|[0-9]*%' | head -1 | sed 's/%//')
        if [ -z "$percent" ]; then
            echo "N/A"
        else
            echo "$percent"
        fi
    }

    df_percent=$(extract_percent "$disk_df")
    lsblk_percent=$(extract_percent "$disk_lsblk")
    findmnt_percent=$(extract_percent "$disk_findmnt")

    # Verify the percentages
    verify_values "disk_percent" "$df_percent" "$lsblk_percent" "$findmnt_percent"

    # Use the primary method (df) for the actual value
    if [ "$disk_df" != "N/A" ]; then
        update_metric_state "disk" "${METRIC_STATES[disk_percent]}" "$disk_df" "${METRIC_MESSAGES[disk_percent]}"
    else
        # Fall back to the first available method
        for method in "$disk_lsblk" "$disk_findmnt"; do
            if [ "$method" != "N/A" ]; then
                update_metric_state "disk" "${METRIC_STATES[disk_percent]}" "$method" "Using fallback method"
                break
            fi
        done

        if [ "${METRIC_VALUES[disk]}" = "" ]; then
            update_metric_state "disk" $STATE_ERROR "N/A" "All disk methods failed"
        fi
    fi
}
