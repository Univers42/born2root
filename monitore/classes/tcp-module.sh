#!/bin/bash

## TCP CONNECTIONS MODULE
tcp_module() {
    register_metric "tcp_connections"

    # Method 1: Using netstat
    get_tcp_netstat() {
        if command -v netstat &>/dev/null; then
            local tcp_count
            tcp_count=$(netstat -an 2>/dev/null | grep ESTABLISHED | wc -l)
            if [ -n "$tcp_count" ]; then
                echo "$tcp_count"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 2: Using ss command
    get_tcp_ss() {
        if command -v ss &>/dev/null; then
            local tcp_count
            tcp_count=$(ss -t state established 2>/dev/null | grep -v "State" | wc -l)
            if [ -n "$tcp_count" ]; then
                echo "$tcp_count"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 3: Using lsof command
    get_tcp_lsof() {
        if command -v lsof &>/dev/null; then
            local tcp_count
            tcp_count=$(lsof -i TCP 2>/dev/null | grep ESTABLISHED | wc -l)
            if [ -n "$tcp_count" ]; then
                echo "$tcp_count"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 4: Reading from /proc/net/tcp
    get_tcp_proc() {
        if [ -f /proc/net/tcp ]; then
            local tcp_count
            tcp_count=$(cat /proc/net/tcp 2>/dev/null | grep " 01 " | wc -l)
            if [ -n "$tcp_count" ]; then
                echo "$tcp_count"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Run all methods
    tcp_netstat=$(get_tcp_netstat)
    tcp_ss=$(get_tcp_ss)
    tcp_lsof=$(get_tcp_lsof)
    tcp_proc=$(get_tcp_proc)

    log_debug "TCP Connection Count Methods:"
    log_debug "  netstat: $tcp_netstat"
    log_debug "  ss: $tcp_ss"
    log_debug "  lsof: $tcp_lsof"
    log_debug "  proc: $tcp_proc"

    # Verify all methods
    verify_values "tcp_connections" "$tcp_netstat" "$tcp_ss" "$tcp_lsof" "$tcp_proc"
}
