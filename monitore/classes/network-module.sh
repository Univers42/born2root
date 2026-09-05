#!/bin/bash

## NETWORK INFORMATION MODULE
network_module() {
    register_metric "network"

    # Method 1: Using hostname and ip commands
    get_network_hostname_ip() {
        if command -v hostname &>/dev/null && command -v ip &>/dev/null; then
            local ip mac
            ip=$(hostname -I 2>/dev/null | awk '{print $1}')
            mac=$(ip link show 2>/dev/null | grep "link/ether" | awk '{print $2}' | head -1)

            if [[ -n "$ip" && -n "$mac" ]]; then
                echo "IP $ip ($mac)"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 2: Using ifconfig command
    get_network_ifconfig() {
        if command -v ifconfig &>/dev/null; then
            local ip mac
            ip=$(ifconfig 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
            mac=$(ifconfig 2>/dev/null | grep "ether" | awk '{print $2}' | head -1)

            if [[ -n "$ip" && -n "$mac" ]]; then
                echo "IP $ip ($mac)"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 3: Using system files directly
    get_network_sysfs() {
        # Get first non-loopback interface
        if [ -d /sys/class/net ]; then
            local interfaces interface
            interfaces=$(ls /sys/class/net/ 2>/dev/null | grep -v "lo")
            interface=$(echo "$interfaces" | head -1)

            if [[ -n "$interface" ]]; then
                local ip mac
                ip=$(ip addr show $interface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
                mac=$(cat /sys/class/net/$interface/address 2>/dev/null)

                if [[ -n "$ip" && -n "$mac" ]]; then
                    echo "IP $ip ($mac)"
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

    # Method 4: Using nmcli
    get_network_nmcli() {
        if command -v nmcli &>/dev/null; then
            local ip mac
            ip=$(nmcli -g IP4.ADDRESS device show 2>/dev/null | head -1 | cut -d/ -f1)
            mac=$(nmcli -g GENERAL.HWADDR device show 2>/dev/null | head -1)

            if [[ -n "$ip" && -n "$mac" ]]; then
                echo "IP $ip ($mac)"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Run all methods
    network_hostname_ip=$(get_network_hostname_ip)
    network_ifconfig=$(get_network_ifconfig)
    network_sysfs=$(get_network_sysfs)
    network_nmcli=$(get_network_nmcli)

    log_debug "Network Information Methods:"
    log_debug "  hostname/ip: $network_hostname_ip"
    log_debug "  ifconfig: $network_ifconfig"
    log_debug "  sysfs: $network_sysfs"
    log_debug "  nmcli: $network_nmcli"

    # For network, mainly check if we get a consistent IP address
    # Extract IP addresses
    extract_ip() {
        echo "$1" | grep -o "IP [0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+" | cut -d' ' -f2
    }

    ip_hostname=$(extract_ip "$network_hostname_ip")
    ip_ifconfig=$(extract_ip "$network_ifconfig")
    ip_sysfs=$(extract_ip "$network_sysfs")
    ip_nmcli=$(extract_ip "$network_nmcli")

    # Determine the best available method
    for method in "$network_hostname_ip" "$network_ifconfig" "$network_sysfs" "$network_nmcli"; do
        if [ "$method" != "N/A" ]; then
            update_metric_state "network" $STATE_OK "$method" "Using first available method"
            break
        fi
    done

    if [ "${METRIC_VALUES[network]}" = "" ]; then
        update_metric_state "network" $STATE_ERROR "N/A" "All network methods failed"
    fi
}
