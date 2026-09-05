#!/bin/bash

# Function to find programs matching a pattern and add selected one to PATH
add_program_to_path() {
    local program_name="$1"
    local search_locations=("$HOME" "/usr/bin" "/usr/local/bin" "/opt" "/bin" "/sbin" "/usr/sbin")
    local found_programs=()

    echo -e "\n🔍 Searching for programs matching pattern: \"$program_name\"...\n"

    # Search for the program in common locations
    for location in "${search_locations[@]}"; do
        if [ -d "$location" ]; then
            while IFS= read -r path; do
                if [ -x "$path" ] && [ -f "$path" ]; then
                    found_programs+=("$path")
                fi
            done < <(find "$location" -name "*$program_name*" -type f 2>/dev/null)
        fi
    done

    # Check if any programs were found
    if [ ${#found_programs[@]} -eq 0 ]; then
        echo -e "❌ No executable programs matching \"$program_name\" were found."
        return 1
    fi

    echo -e "✅ Found ${#found_programs[@]} possible matches:\n"

    # Display found programs
    for i in "${!found_programs[@]}"; do
        echo "[$((i + 1))] ${found_programs[$i]}"
    done

    # Ask user to select a program
    echo -e "\n📝 Please select which program to add to your PATH [1-${#found_programs[@]}]: "
    read -r selection

    # Validate selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#found_programs[@]} ]; then
        echo -e "❌ Invalid selection. Please enter a number between 1 and ${#found_programs[@]}."
        return 1
    fi

    # Get the selected program path
    selected_path="${found_programs[$((selection - 1))]}"
    selected_dir=$(dirname "$selected_path")

    echo -e "\n🔍 Selected program: $selected_path"

    # Check if the directory is already in PATH
    if [[ ":$PATH:" == *":$selected_dir:"* ]]; then
        echo -e "✅ The directory \"$selected_dir\" is already in your PATH."
        echo -e "✅ You can run \"$(basename "$selected_path")\" from anywhere in the terminal."
        return 0
    fi

    # Determine which shell configuration file to use
    shell_config=""
    if [[ "$SHELL" == *"zsh"* ]]; then
        shell_config="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        shell_config="$HOME/.bashrc"
    else
        # Try to find a reasonable default
        for config in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
            if [ -f "$config" ]; then
                shell_config="$config"
                break
            fi
        done
    fi

    if [ -z "$shell_config" ]; then
        echo -e "❌ Could not determine shell configuration file. Please add the following line manually:"
        echo -e "export PATH=\"\$PATH:$selected_dir\""
        return 1
    fi

    # Ask for confirmation before modifying the shell configuration
    echo -e "\n⚠️  I'm about to add \"$selected_dir\" to your PATH by modifying $shell_config"
    echo -e "👉 Do you want to proceed? [y/N]: "
    read -r confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "❌ Operation cancelled by user."
        return 1
    fi

    # Add the directory to PATH in shell configuration file
    echo -e "\n# Added by add_program_to_path script on $(date)" >>"$shell_config"
    echo "export PATH=\"\$PATH:$selected_dir\"" >>"$shell_config"

    echo -e "\n✅ Successfully added \"$selected_dir\" to PATH in $shell_config"
    echo -e "✅ To apply changes to your current session, run: source $shell_config"
    echo -e "✅ After that, you can run \"$(basename "$selected_path")\" from anywhere in the terminal."

    # Create a symbolic link option
    echo -e "\n📝 Would you like to create a symbolic link in /usr/local/bin instead? [y/N]: "
    read -r create_symlink

    if [[ "$create_symlink" =~ ^[Yy]$ ]]; then
        local program_basename=$(basename "$selected_path")
        echo -e "📝 Enter a name for the command (default: $program_basename): "
        read -r symlink_name

        # Use default name if none provided
        if [ -z "$symlink_name" ]; then
            symlink_name="$program_basename"
        fi

        # Create the symlink
        if sudo ln -sf "$selected_path" "/usr/local/bin/$symlink_name"; then
            echo -e "✅ Successfully created symbolic link: /usr/local/bin/$symlink_name -> $selected_path"
            echo -e "✅ You can now run \"$symlink_name\" from anywhere in the terminal."
        else
            echo -e "❌ Failed to create symbolic link. You may need sudo permissions."
        fi
    fi

    # Print summary
    echo -e "\n📋 SUMMARY OF CHANGES:"
    echo -e "🔹 Program: $(basename "$selected_path")"
    echo -e "🔹 Full path: $selected_path"
    if [[ "$create_symlink" =~ ^[Yy]$ ]]; then
        echo -e "🔹 Symbolic link: /usr/local/bin/$symlink_name"
    fi
    echo -e "🔹 Shell configuration: $shell_config"
    echo -e "🔹 PATH update: export PATH=\"\$PATH:$selected_dir\""
    echo -e "🔹 To apply changes: source $shell_config"

    return 0
}

# Check if a program name was provided
if [ -z "$1" ]; then
    echo -e "❌ Usage: $0 <program_name>"
    echo -e "Example: $0 discord"
    exit 1
fi

# Run the function with the provided program name
add_program_to_path "$1"
