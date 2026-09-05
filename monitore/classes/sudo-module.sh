#!/bin/bash

## SUDO COMMAND COUNT MODULE
sudo_command_module() {
    register_metric "sudo_count"

    # Method 1: Using journalctl
    get_sudo_journalctl() {
        if command -v journalctl &>/dev/null; then
            local sudo_count=$(journalctl _COMM=sudo 2>/dev/null | grep COMMAND | wc -l)
            if [ -n "$sudo_count" ]; then
                echo "$sudo_count"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 2: Using auth.log
    get_sudo_authlog() {
        if [ -f /var/log/auth.log ]; then
            local sudo_count=$(grep "sudo:" /var/log/auth.log 2>/dev/null | grep "COMMAND" | wc -l)
            if [ -n "$sudo_count" ]; then
                echo "$sudo_count"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 3: Using secure log (RHEL/CentOS)
    get_sudo_secure() {
        if [ -f /var/log/secure ]; then
            local sudo_count=$(grep "sudo:" /var/log/secure 2>/dev/null | grep "COMMAND" | wc -l)
            if [ -n "$sudo_count" ]; then
                echo "$sudo_count"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 4: Using custom sudo log if configured
    get_sudo_custom() {
        if [ -f /var/log/sudo.log ]; then
            local sudo_count=$(grep "COMMAND" /var/log/sudo.log 2>/dev/null | wc -l)
            if [ -n "$sudo_count" ]; then
                echo "$sudo_count"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 5: Using ausearch if available
    get_sudo_ausearch() {
        if command -v ausearch &>/dev/null; then
            local sudo_count=$(ausearch -m USER_CMD -c sudo 2>/dev/null | grep -c "type=USER_CMD")
            if [ -n "$sudo_count" ]; then
                echo "$sudo_count"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Run all methods
    sudo_journalctl=$(get_sudo_journalctl)
    sudo_authlog=$(get_sudo_authlog)
    sudo_secure=$(get_sudo_secure)
    sudo_custom=$(get_sudo_custom)
    sudo_ausearch=$(get_sudo_ausearch)

    log_debug "Sudo Command Count Methods:"
    log_debug "  journalctl: $sudo_journalctl"
    log_debug "  auth.log: $sudo_authlog"
    log_debug "  secure log: $sudo_secure"
    log_debug "  custom log: $sudo_custom"
    log_debug "  ausearch: $sudo_ausearch"

    # Verify all methods
    verify_values "sudo_count" "$sudo_journalctl" "$sudo_authlog" "$sudo_secure" "$sudo_custom" "$sudo_ausearch"
}
