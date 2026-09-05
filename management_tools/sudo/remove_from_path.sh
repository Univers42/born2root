#!/bin/bash

# Function to remove a program from PATH and delete symbolic links
remove_program() {
    local program_name="$1"
    local shell_configs=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile")
    local found_in_path=()
    local found_symlinks=()

    echo -e "\n🔍 Searching for \"$program_name\" in your system...\n"

    # Search for entries in PATH directories
    IFS=':' read -ra PATH_DIRS <<<"$PATH"
    for dir in "${PATH_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            while IFS= read -r path; do
                if [ -x "$path" ] && [ -f "$path" ]; then
                    found_in_path+=("$path")
                fi
            done < <(find "$dir" -name "*$program_name*" 2>/dev/null)
        fi
    done

    # Search for symbolic links in common bin directories
    for dir in "/usr/local/bin" "/usr/bin" "/bin" "$HOME/bin"; do
        if [ -d "$dir" ]; then
            while IFS= read -r symlink; do
                if [ -L "$symlink" ] && [[ "$(basename "$symlink")" == *"$program_name"* ]]; then
                    found_symlinks+=("$symlink")
                fi
            done < <(find "$dir" -type l -name "*$program_name*" 2>/dev/null)
        fi
    done

    # Combine both lists and remove duplicates
    local all_found=("${found_in_path[@]}" "${found_symlinks[@]}")
    all_found=($(printf "%s\n" "${all_found[@]}" | sort -u))

    # Check if any programs were found
    if [ ${#all_found[@]} -eq 0 ]; then
        echo -e "❌ No programs matching \"$program_name\" were found in your PATH or as symbolic links."
        return 1
    fi

    echo -e "✅ Found ${#all_found[@]} possible matches:\n"

    # Display found programs
    for i in "${!all_found[@]}"; do
        local path="${all_found[$i]}"
        local type="Regular file"

        if [ -L "$path" ]; then
            type="Symbolic link → $(readlink "$path")"
        fi

        echo "[$((i + 1))] $path ($type)"
    done

    # Ask user to select a program
    echo -e "\n📝 Please select which program to remove [1-${#all_found[@]}]: "
    read -r selection

    # Validate selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#all_found[@]} ]; then
        echo -e "❌ Invalid selection. Please enter a number between 1 and ${#all_found[@]}."
        return 1
    fi

    # Get the selected program path
    selected_path="${all_found[$((selection - 1))]}"
    selected_dir=$(dirname "$selected_path")
    selected_name=$(basename "$selected_path")

    echo -e "\n🔍 Selected program: $selected_path"

    # Ask for confirmation before proceeding
    echo -e "\n⚠️  I'm about to remove \"$selected_path\" from your system."
    echo -e "👉 Do you want to proceed? [y/N]: "
    read -r confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "❌ Operation cancelled by user."
        return 1
    fi

    # 1. Remove symbolic link if it is one
    if [ -L "$selected_path" ]; then
        echo -e "\n🔄 Removing symbolic link: $selected_path"
        if sudo rm "$selected_path"; then
            echo -e "✅ Successfully removed symbolic link."
        else
            echo -e "❌ Failed to remove symbolic link. You may need sudo permissions."
            echo -e "   Try: sudo rm \"$selected_path\""
        fi
    fi

    # 2. Search for and clean up PATH entries in shell config files
    local path_cleaned=false
    local target_path=""

    # If it's a symlink, we want to look for the target in PATH entries
    if [ -L "$selected_path" ]; then
        target_path=$(readlink "$selected_path")
        selected_dir=$(dirname "$target_path")
    fi

    for config in "${shell_configs[@]}"; do
        if [ -f "$config" ]; then
            echo -e "\n🔍 Checking $config for PATH entries..."

            # Make a backup of the config file
            cp "$config" "${config}.bak"

            # Search for PATH entries that include the directory
            if grep -q "PATH.*:${selected_dir}:" "$config" || grep -q "PATH.*:${selected_dir}\$" "$config"; then
                # Create a temporary file
                temp_file=$(mktemp)

                # Filter out the PATH lines that contain our directory
                grep -v "export PATH=.*:${selected_dir}\\(:.*\\)\\?\"\\?$" "$config" >"$temp_file"
                mv "$temp_file" "$config"

                echo -e "✅ Removed PATH entry for \"$selected_dir\" from $config"
                path_cleaned=true
            fi
        fi
    done

    if [ "$path_cleaned" = false ]; then
        echo -e "\n⚠️  No PATH entries for \"$selected_dir\" were found in shell configuration files."
    fi

    # Print summary of changes
    echo -e "\n📋 SUMMARY OF CHANGES:"
    echo -e "🔹 Program: $selected_name"
    echo -e "🔹 Full path: $selected_path"

    if [ -L "$selected_path" ]; then
        echo -e "🔹 Symbolic link removed: $selected_path"
        echo -e "🔹 Target was: $(readlink "$selected_path")"
    fi

    if [ "$path_cleaned" = true ]; then
        echo -e "🔹 PATH entries removed from shell configuration files"
        echo -e "🔹 Backup files created: ${shell_configs[*]/%/.bak}"
        echo -e "🔹 To apply changes to your current session, restart your terminal or run: source <your-shell-config>"
    fi

    echo -e "\n✅ Cleanup completed successfully!"

    return 0
}

# Check if a program name was provided
if [ -z "$1" ]; then
    echo -e "❌ Usage: $0 <program_name>"
    echo -e "Example: $0 discord"
    exit 1
fi

# Get current date and user for logging
echo "Current Date and Time (UTC): $(date -u +"%Y-%m-%d %H:%M:%S")"
echo "Current User's Login: $(whoami)"
echo ""

# Run the function with the provided program name
remove_program "$1"
