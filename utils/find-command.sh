#!/bin/bash

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored text
print_color() {
    local color="$1"
    local text="$2"
    echo -e "${color}${text}${NC}"
}

# Function to display help message
show_help() {
    echo "Usage: $(basename "$0") [options] COMMAND_NAME [COMMAND_NAME...]"
    echo
    echo "Search for packages that provide specified commands."
    echo
    echo "Options:"
    echo "  -h, --help      Show this help message and exit"
    echo "  -a, --all       Show all matches, not just the most likely ones"
    echo "  -u, --update    Force update apt-file database"
    echo "  -q, --quiet     Quiet mode (less verbose output)"
    echo
    echo "Example:"
    echo "  $(basename "$0") netstat ifconfig"
    echo "  $(basename "$0") -a grep"
    exit 0
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to display spinner during operations
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p "$pid" >/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Parse arguments
ALL_MATCHES=0
FORCE_UPDATE=0
QUIET=0
SEARCH_TERMS=()

while [[ $# -gt 0 ]]; do
    case $1 in
    -h | --help)
        show_help
        ;;
    -a | --all)
        ALL_MATCHES=1
        shift
        ;;
    -u | --update)
        FORCE_UPDATE=1
        shift
        ;;
    -q | --quiet)
        QUIET=1
        shift
        ;;
    -*)
        print_color "$RED" "Unknown option: $1"
        show_help
        ;;
    *)
        SEARCH_TERMS+=("$1")
        shift
        ;;
    esac
done

# Check if search terms were provided
if [ ${#SEARCH_TERMS[@]} -eq 0 ]; then
    print_color "$RED" "Error: No search terms provided."
    show_help
fi

# Check and install apt-file if not present
if ! command_exists apt-file; then
    print_color "$YELLOW" "apt-file is not installed. Installing it now..."
    if [ "$QUIET" -eq 0 ]; then
        sudo apt update && sudo apt install -y apt-file
    else
        sudo apt update >/dev/null 2>&1 && sudo apt install -y apt-file >/dev/null 2>&1
    fi

    if [ $? -ne 0 ]; then
        print_color "$RED" "Failed to install apt-file. Please install it manually with: sudo apt install apt-file"
        exit 1
    fi
    print_color "$GREEN" "apt-file installed successfully."
fi

# Update apt-file database if needed
APT_FILE_UPDATED=0
if [ "$FORCE_UPDATE" -eq 1 ] || [ ! -f /var/cache/apt/apt-file/index.apt-file ]; then
    print_color "$YELLOW" "Updating apt-file database (this may take a moment)..."
    if [ "$QUIET" -eq 0 ]; then
        sudo apt-file update &
        spinner $!
    else
        sudo apt-file update >/dev/null 2>&1
    fi

    if [ $? -ne 0 ]; then
        print_color "$RED" "Failed to update apt-file database."
        exit 1
    fi
    APT_FILE_UPDATED=1
    print_color "$GREEN" "apt-file database updated successfully."
fi

# Process each search term
for term in "${SEARCH_TERMS[@]}"; do
    print_color "$CYAN" "\n==== Searching for command: '$term' ===="

    # Check if the command already exists
    if command_exists "$term"; then
        path_to_command=$(which "$term")
        package=$(dpkg -S "$path_to_command" 2>/dev/null | cut -d: -f1)
        if [ -n "$package" ]; then
            print_color "$GREEN" "✓ Command '$term' is already installed from package: $package"
            print_color "$BLUE" "  Location: $path_to_command"
            continue
        fi
    fi

    # Primary search with apt-file
    print_color "$MAGENTA" "Searching with apt-file..."
    # Look for exact matches in bin directories first
    apt_file_results=$(apt-file search -l "/bin/$term$\|/sbin/$term$\|/usr/bin/$term$\|/usr/sbin/$term$" 2>/dev/null)

    if [ -z "$apt_file_results" ]; then
        # If no exact matches, search for the command name anywhere
        apt_file_results=$(apt-file search -l "$term" 2>/dev/null | grep -E "/bin/|/sbin/")
    fi

    if [ -n "$apt_file_results" ]; then
        print_color "$GREEN" "Found potential packages:"

        if [ "$ALL_MATCHES" -eq 1 ]; then
            # Show all results
            echo "$apt_file_results" | while read -r line; do
                package=$(echo "$line" | cut -d: -f1)
                path=$(echo "$line" | cut -d: -f2)
                print_color "$YELLOW" "  • $package: $path"
            done
        else
            # Show only the most likely matches (first 3)
            echo "$apt_file_results" | head -n 3 | while read -r line; do
                package=$(echo "$line" | cut -d: -f1)
                path=$(echo "$line" | cut -d: -f2)
                print_color "$YELLOW" "  • $package: $path"
            done

            # If there are more results, show count
            total_results=$(echo "$apt_file_results" | wc -l)
            if [ "$total_results" -gt 3 ]; then
                print_color "$BLUE" "    (and $(($total_results - 3)) more results, use --all to show all)"
            fi
        fi

        # Installation suggestion
        first_package=$(echo "$apt_file_results" | head -n 1 | cut -d: -f1)
        print_color "$GREEN" "\nTo install, run: sudo apt install $first_package"
    else
        print_color "$RED" "No packages found providing '$term' in standard binary locations."

        # Try command-not-found if available
        if command_exists command-not-found; then
            print_color "$MAGENTA" "Checking with command-not-found..."
            cnf_output=$(command-not-found "$term" 2>&1)
            if [[ "$cnf_output" != *"command not found"* ]]; then
                print_color "$GREEN" "$cnf_output"
            fi
        else
            print_color "$YELLOW" "Tip: Install 'command-not-found' package for additional help with missing commands."
        fi

        # Last resort: suggest similar packages
        print_color "$MAGENTA" "Searching for similar packages..."
        similar_pkgs=$(apt-cache search "$term" | head -n 3)
        if [ -n "$similar_pkgs" ]; then
            print_color "$YELLOW" "Packages with similar names:"
            echo "$similar_pkgs"
        fi
    fi
done

print_color "$CYAN" "\nSearch complete!"
exit 0
