#!/bin/bash

###################### GLOBAL CONFIGURATION ########################
# Enable/disable debug output (set to false for production)
DEBUG=false

# Define return states for verification
STATE_OK=0
STATE_WARNING=1
STATE_ERROR=2

# Define threshold for acceptable differences (in percent)
THRESHOLD_PERCENT=5

# Colors for terminal output
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Enhanced colors and formatting
BOLD='\033[1m'
UNDERLINE='\033[4m'
BLINK='\033[5m'
CYAN='\033[0;36m'
LIGHT_BLUE='\033[0;94m'
PURPLE='\033[0;35m'
DARK_GRAY='\033[1;30m'
LIGHT_GRAY='\033[0;37m'

###################### STATE MACHINE FRAMEWORK ######################
# State tracking array for all metrics
declare -A METRIC_STATES
declare -A METRIC_VALUES
declare -A METRIC_MESSAGES

# Initialize the state machine
init_state_machine() {
    # Initialize state tracking
    METRIC_STATES=()
    METRIC_VALUES=()
    METRIC_MESSAGES=()
}

# Register a metric with the state machine
register_metric() {
    local metric_name="$1"
    METRIC_STATES["$metric_name"]=$STATE_OK
    METRIC_VALUES["$metric_name"]=""
    METRIC_MESSAGES["$metric_name"]=""
}

# Update metric state
update_metric_state() {
    local metric_name="$1"
    local state="$2"
    local value="$3"
    local message="$4"

    METRIC_STATES["$metric_name"]=$state
    METRIC_VALUES["$metric_name"]="$value"
    METRIC_MESSAGES["$metric_name"]="$message"
}

# Get a human-readable state name
get_state_name() {
    local state=$1
    case $state in
    $STATE_OK) echo "OK" ;;
    $STATE_WARNING) echo "WARNING" ;;
    $STATE_ERROR) echo "ERROR" ;;
    *) echo "UNKNOWN" ;;
    esac
}

# Get colored output for state
get_state_color() {
    local state=$1
    case $state in
    $STATE_OK) echo "${GREEN}$(get_state_name $state)${NC}" ;;
    $STATE_WARNING) echo "${YELLOW}$(get_state_name $state)${NC}" ;;
    $STATE_ERROR) echo "${RED}$(get_state_name $state)${NC}" ;;
    *) echo "UNKNOWN" ;;
    esac
}

###################### LOGGING & DEBUG UTILITIES ######################
log_debug() {
    if [ "$DEBUG" = true ]; then
        echo "[DEBUG] $*"
    fi
}

log_info() {
    echo "[INFO] $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Print verification results for a single test with enhanced visuals
print_verification_result() {
    local metric_name="$1"
    local state="${METRIC_STATES[$metric_name]}"
    local value="${METRIC_VALUES[$metric_name]}"
    local message="${METRIC_MESSAGES[$metric_name]}"

    # Metric name with appropriate color based on state
    local color_prefix=""
    case $state in
    $STATE_OK) color_prefix="${GREEN}" ;;
    $STATE_WARNING) color_prefix="${YELLOW}" ;;
    $STATE_ERROR) color_prefix="${RED}" ;;
    *) color_prefix="${LIGHT_GRAY}" ;;
    esac

    # Print metric indicator with fancy format
    echo -e "${DARK_GRAY}├─${color_prefix}${BOLD}${metric_name}${NC} - $(get_state_color $state)${DARK_GRAY} ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄"

    # Print value with appropriate color
    echo -e "${DARK_GRAY}│ ${CYAN}Value:${NC} ${LIGHT_BLUE}$value${NC}"

    # Print message if available
    if [ -n "$message" ]; then
        echo -e "${DARK_GRAY}│ ${PURPLE}Info:${NC} $message"
    fi

    # Add a spacer line
    echo -e "${DARK_GRAY}│${NC}"
}

# Print all verification results with an enhanced header and footer
print_system_analysis() {
    echo -e "\n${BOLD}${UNDERLINE}${CYAN}====== System Metrics Analysis ======${NC}\n"

    # Draw the top border
    echo -e "${DARK_GRAY}┌────────────────────────────────────────────────────────────────┐${NC}"

    # Group metrics by category for better organization
    echo -e "${DARK_GRAY}│ ${BOLD}${LIGHT_BLUE}SYSTEM ARCHITECTURE${NC}                                          ${DARK_GRAY}│${NC}"
    print_verification_result "architecture"
    print_verification_result "cpu_physical"
    print_verification_result "cpu_core"

    echo -e "${DARK_GRAY}│ ${BOLD}${LIGHT_BLUE}RESOURCE UTILIZATION${NC}                                        ${DARK_GRAY}│${NC}"
    print_verification_result "memory"
    print_verification_result "disk"
    print_verification_result "cpu_load"

    echo -e "${DARK_GRAY}│ ${BOLD}${LIGHT_BLUE}SYSTEM INFORMATION${NC}                                          ${DARK_GRAY}│${NC}"
    print_verification_result "last_boot"
    print_verification_result "lvm_use"
    print_verification_result "network"

    echo -e "${DARK_GRAY}│ ${BOLD}${LIGHT_BLUE}ACTIVITY METRICS${NC}                                            ${DARK_GRAY}│${NC}"
    print_verification_result "tcp_connections"
    print_verification_result "user_log"
    print_verification_result "sudo_count"

    # Draw the bottom border
    echo -e "${DARK_GRAY}└────────────────────────────────────────────────────────────────┘${NC}"

    # Add loading message
    echo -e "\n${YELLOW}${BLINK}Preparing wall message...${NC}"
}

###################### VERIFICATION ENGINE ######################
# Compare numeric values with a threshold
compare_numeric_values() {
    local reference="$1"
    local value="$2"
    local threshold="$3"

    # Remove any non-numeric characters (except decimal point)
    reference=$(echo "$reference" | sed 's/[^0-9.]//g')
    value=$(echo "$value" | sed 's/[^0-9.]//g')

    # Check for empty or zero reference to avoid division by zero
    if [[ -z "$reference" || "$reference" == "0" || "$reference" == "0.0" ]]; then
        return $STATE_WARNING
    fi

    # Calculate the difference
    local diff percent_diff
    diff=$(awk "BEGIN {print sqrt(($reference-$value)^2)}")
    percent_diff=$(awk "BEGIN {print $reference != 0 ? ($diff/$reference)*100 : 100}")

    # Check if the difference is within the threshold
    if (($(awk "BEGIN {print ($percent_diff > $threshold) ? 1 : 0}"))); then
        return $STATE_WARNING
    else
        return $STATE_OK
    fi
}

# Compare string values for equality
compare_string_values() {
    local reference="$1"
    local value="$2"

    if [ "$reference" = "$value" ]; then
        return $STATE_OK
    else
        return $STATE_WARNING
    fi
}

# Verify a set of values
verify_values() {
    local metric_name="$1"
    shift
    local values=("$@")

    # Need at least one value
    if [ ${#values[@]} -eq 0 ]; then
        update_metric_state "$metric_name" $STATE_ERROR "N/A" "No values available to verify"
        return
    fi

    # With only one value, we can't verify
    if [ ${#values[@]} -eq 1 ]; then
        if [ "${values[0]}" = "N/A" ]; then
            update_metric_state "$metric_name" $STATE_WARNING "${values[0]}" "Only one method available and it failed"
        else
            update_metric_state "$metric_name" $STATE_OK "${values[0]}" "Only one method available"
        fi
        return
    fi

    # Find first valid value to use as reference
    local reference=""
    for val in "${values[@]}"; do
        if [ "$val" != "N/A" ]; then
            reference="$val"
            break
        fi
    done

    if [ -z "$reference" ]; then
        update_metric_state "$metric_name" $STATE_ERROR "N/A" "All methods failed"
        return
    fi

    # Compare all values to the reference
    local all_ok=true
    local warnings=0
    local errors=0
    local max_diff=0
    local result_message=""

    for val in "${values[@]}"; do
        if [ "$val" = "N/A" ]; then
            continue
        fi

        # Check if the values are numeric (contains digits)
        if [[ "$reference" =~ [0-9] && "$val" =~ [0-9] ]]; then
            # Extract numeric part for verification if needed
            local ref_num val_num
            ref_num=$(echo "$reference" | grep -o '[0-9]*\.*[0-9]*' | head -1)
            val_num=$(echo "$val" | grep -o '[0-9]*\.*[0-9]*' | head -1)

            # Skip if ref_num is 0 to avoid division by zero
            if [[ -z "$ref_num" || "$ref_num" == "0" || "$ref_num" == "0.0" ]]; then
                continue
            fi

            compare_numeric_values "$ref_num" "$val_num" $THRESHOLD_PERCENT
            result=$?

            # Calculate difference for reporting
            local diff
            diff=$(awk "BEGIN {print sqrt(($ref_num-$val_num)^2)}")
            if [[ -n "$diff" && "$diff" != "0" && "$max_diff" != "0" ]]; then
                if (($(awk "BEGIN {print ($diff > $max_diff) ? 1 : 0}"))); then
                    max_diff=$diff
                fi
            fi
        else
            compare_string_values "$reference" "$val"
            result=$?
        fi

        if [ $result -eq $STATE_WARNING ]; then
            all_ok=false
            warnings=$((warnings + 1))
            result_message="Values differ by more than threshold"
        elif [ $result -eq $STATE_ERROR ]; then
            all_ok=false
            errors=$((errors + 1))
            result_message="Critical error in comparison"
        fi
    done

    # Determine final state
    if $all_ok; then
        update_metric_state "$metric_name" $STATE_OK "$reference" "All methods consistent (max diff: $max_diff)"
    elif [ $errors -gt 0 ]; then
        update_metric_state "$metric_name" $STATE_ERROR "$reference" "$errors errors, $warnings warnings. $result_message"
    elif [ $warnings -gt 0 ]; then
        update_metric_state "$metric_name" $STATE_WARNING "$reference" "$warnings methods differed. $result_message"
    else
        update_metric_state "$metric_name" $STATE_OK "$reference" "No errors detected"
    fi
}

# Include each module
source ./classes/architecture-module.sh
source ./classes/cpu-physical-module.sh
source ./classes/cpu-core-module.sh
source ./classes/memory-module.sh
source ./classes/disk-module.sh
source ./classes/cpu-load-module.sh
source ./classes/last-boot-module.sh
source ./classes/lvm-module.sh
source ./classes/tcp-module.sh
source ./classes/user-login-module.sh
source ./classes/network-module.sh
source ./classes/sudo-module.sh

###################### MAIN EXECUTION FLOW ######################
main() {
    # Initialize state machine
    init_state_machine

    # Run all modules
    architecture_module
    cpu_physical_module
    cpu_core_module
    memory_module
    disk_module
    cpu_load_module
    last_boot_module
    lvm_module
    tcp_module
    user_login_module
    network_module
    sudo_command_module

    # Store metrics for wall message
    local arch="${METRIC_VALUES[architecture]}"
    local cpu_physical="${METRIC_VALUES[cpu_physical]}"
    local cpu_core="${METRIC_VALUES[cpu_core]}"
    local memory="${METRIC_VALUES[memory]}"
    local disk="${METRIC_VALUES[disk]}"
    local cpu_load="${METRIC_VALUES[cpu_load]}"
    local last_boot="${METRIC_VALUES[last_boot]}"
    local lvm_use="${METRIC_VALUES[lvm_use]}"
    local tcp_connections="${METRIC_VALUES[tcp_connections]}"
    local user_log="${METRIC_VALUES[user_log]}"
    local network="${METRIC_VALUES[network]}"
    local sudo_count="${METRIC_VALUES[sudo_count]}"

    # Display results with enhanced visuals
    print_system_analysis

    # Wait briefly then clear the screen
    sleep 3
    clear

    # Create an ASCII art header for the final output
    local ascii_header="
    ██████╗ ██████╗ ██████╗ ███████╗    ██╗    ██╗ █████╗ ██╗     ██╗
    ██╔══██╗██╔══██╗██╔══██╗██╔════╝    ██║    ██║██╔══██╗██║     ██║
    ██████╔╝██████╔╝██████╔╝█████╗      ██║ █╗ ██║███████║██║     ██║
    ██╔══██╗██╔══██╗██╔══██╗██╔══╝      ██║███╗██║██╔══██║██║     ██║
    ██████╔╝██║  ██║██████╔╝███████╗    ╚███╔███╔╝██║  ██║███████╗███████╗
    ╚═════╝ ╚═╝  ╚═╝╚═════╝ ╚══════╝     ╚══╝╚══╝ ╚═╝  ╚═╝╚══════╝╚══════╝
    "

    # Prepare wall message
    current_date=$(date -u "+%Y-%m-%d %H:%M:%S")
    current_user=$(whoami)
    if [ -n "$SUDO_USER" ]; then
        current_user=$SUDO_USER
    fi
    BROADCAST_MSG="$(echo "Broadcast message from $current_user@$(hostname) ($(tty | sed 's/\/dev\/pts\//tty/')) ($(date '+%a %b %d %H:%M:%S %Y')):")"

    FINAL_OUTPUT="${ascii_header}
${BROADCAST_MSG}
${CYAN}#Architecture:${NC} $arch
${CYAN}#CPU physical:${NC} $cpu_physical
${CYAN}#vCPU:${NC} $cpu_core
${CYAN}#Memory Usage:${NC} $memory
${CYAN}#Disk Usage:${NC} $disk
${CYAN}#CPU load:${NC} $cpu_load
${CYAN}#Last boot:${NC} $last_boot
${CYAN}#LVM use:${NC} $lvm_use
${CYAN}#TCP Connections:${NC} $tcp_connections ESTABLISHED
${CYAN}#User log:${NC} $user_log
${CYAN}#Network:${NC} $network
${CYAN}#Sudo:${NC} $sudo_count cmd
"

    # Display the wall message directly (without using 'wall' command which might prompt)
    echo -e "$FINAL_OUTPUT"

    # Send a plain text version to all terminals with wall if we have privileges
    # Strip ANSI color codes for the wall command
    PLAIN_OUTPUT=" $BROADCAST_MSG
#Architecture: $arch
#CPU physical : $cpu_physical
#vCPU : $cpu_core
#Memory Usage: $memory
#Disk Usage: $disk
#CPU load: $cpu_load
#Last boot: $last_boot
#LVM use: $lvm_use
#TCP Connections : $tcp_connections ESTABLISHED
#User log: $user_log
#Network: $network
#Sudo : $sudo_count cmd
"

    wall "$PLAIN_OUTPUT" 2>/dev/null || true
}

# Run the main function
main
