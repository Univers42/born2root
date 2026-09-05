#!/bin/bash

## USER LOGIN MODULE
user_login_module() {
    register_metric "user_log"

    # Method 1: Using users command
    get_users_count() {
        if command -v users &>/dev/null; then
            local users_output
            users_output=$(users 2>/dev/null)
            if [ -n "$users_output" ]; then
                echo "$(echo "$users_output" | wc -w)"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 2: Using who command
    get_who_count() {
        if command -v who &>/dev/null; then
            local who_output
            who_output=$(who 2>/dev/null)
            if [ -n "$who_output" ]; then
                echo "$(echo "$who_output" | wc -l)"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 3: Using w command
    get_w_count() {
        if command -v w &>/dev/null; then
            local w_output
            w_output=$(w -h 2>/dev/null)
            if [ -n "$w_output" ]; then
                echo "$(echo "$w_output" | wc -l)"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Method 4: Using last for currently logged in
    get_last_count() {
        if command -v last &>/dev/null; then
            local last_output
            last_output=$(last 2>/dev/null | grep "still logged in")
            if [ -n "$last_output" ]; then
                echo "$(echo "$last_output" | wc -l)"
            else
                echo "0" # No users still logged in is valid
            fi
        else
            echo "N/A"
        fi
    }

    # Method 5: Using loginctl for systemd systems
    get_loginctl_count() {
        if command -v loginctl &>/dev/null; then
            local loginctl_output
            loginctl_output=$(loginctl list-sessions --no-legend 2>/dev/null)
            if [ -n "$loginctl_output" ]; then
                echo "$(echo "$loginctl_output" | wc -l)"
            else
                echo "N/A"
            fi
        else
            echo "N/A"
        fi
    }

    # Run all methods
    users_count=$(get_users_count)
    who_count=$(get_who_count)
    w_count=$(get_w_count)
    last_count=$(get_last_count)
    loginctl_count=$(get_loginctl_count)

    log_debug "User Login Count Methods:"
    log_debug "  users: $users_count"
    log_debug "  who: $who_count"
    log_debug "  w: $w_count"
    log_debug "  last: $last_count"
    log_debug "  loginctl: $loginctl_count"

    # Verify all methods
    verify_values "user_log" "$users_count" "$who_count" "$w_count" "$last_count" "$loginctl_count"
}
