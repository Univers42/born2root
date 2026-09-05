#!/bin/bash

## LVM USAGE MODULE
lvm_module() {
    register_metric "lvm_use"

    # Method 1: Using lsblk
    get_lvm_lsblk() {
        if command -v lsblk &>/dev/null; then
            local lvm_count
            lvm_count=$(lsblk 2>/dev/null | grep "lvm" | wc -l)
            if [ $lvm_count -eq 0 ]; then
                echo "no"
            else
                echo "yes"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 2: Using lvs command
    get_lvm_lvs() {
        if command -v lvs &>/dev/null; then
            local lvs_output
            lvs_output=$(lvs 2>/dev/null)
            if [ -z "$lvs_output" ]; then
                echo "no"
            else
                echo "yes"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 3: Using vgs command
    get_lvm_vgs() {
        if command -v vgs &>/dev/null; then
            local vgs_output
            vgs_output=$(vgs 2>/dev/null)
            if [ -z "$vgs_output" ]; then
                echo "no"
            else
                echo "yes"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 4: Checking /dev/mapper
    get_lvm_mapper() {
        if [ -d /dev/mapper ]; then
            local mapper_entries
            mapper_entries=$(ls -la /dev/mapper/ 2>/dev/null | grep -v control | wc -l)
            if [ $mapper_entries -le 1 ]; then
                echo "no"
            else
                echo "yes"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 5: Checking /etc/fstab
    get_lvm_fstab() {
        if [ -f /etc/fstab ]; then
            local fstab_lvm
            fstab_lvm=$(grep "/dev/mapper" /etc/fstab 2>/dev/null | wc -l)
            if [ $fstab_lvm -eq 0 ]; then
                echo "no"
            else
                echo "yes"
            fi
        else
            echo "N/A"
        fi
    }

    # Run all methods
    lvm_lsblk=$(get_lvm_lsblk)
    lvm_lvs=$(get_lvm_lvs)
    lvm_vgs=$(get_lvm_vgs)
    lvm_mapper=$(get_lvm_mapper)
    lvm_fstab=$(get_lvm_fstab)

    log_debug "LVM Usage Detection Methods:"
    log_debug "  lsblk: $lvm_lsblk"
    log_debug "  lvs: $lvm_lvs"
    log_debug "  vgs: $lvm_vgs"
    log_debug "  mapper: $lvm_mapper"
    log_debug "  fstab: $lvm_fstab"

    # Count the number of "yes" responses from methods that returned a result
    local yes_count=0
    local available_methods=0

    for result in "$lvm_lsblk" "$lvm_lvs" "$lvm_vgs" "$lvm_mapper" "$lvm_fstab"; do
        if [ "$result" != "N/A" ]; then
            available_methods=$((available_methods + 1))
            if [ "$result" = "yes" ]; then
                yes_count=$((yes_count + 1))
            fi
        fi
    done

    # If more than half of the available methods say "yes", we'll use "yes"
    if [ $available_methods -gt 0 ]; then
        if [ $yes_count -gt $((available_methods / 2)) ]; then
            update_metric_state "lvm_use" $STATE_OK "yes" "$yes_count of $available_methods methods confirmed LVM usage"
        else
            update_metric_state "lvm_use" $STATE_OK "no" "Only $yes_count of $available_methods methods detected LVM"
        fi
    else
        update_metric_state "lvm_use" $STATE_WARNING "N/A" "No methods available to detect LVM"
    fi
}
