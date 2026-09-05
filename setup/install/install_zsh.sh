#!/bin/bash

# Function to change default shell to zsh
change_default_shell() {
    # Check if zsh is in the list of available shells
    if grep -q "$(which zsh)" /etc/shells; then
        echo "zsh is available in /etc/shells"

        # Check if zsh is already the default shell
        if [[ "$SHELL" == *"zsh"* ]]; then
            echo "zsh is already your default shell."
        else
            echo "Changing default shell to zsh..."
            chsh -s $(which zsh)
            echo "Shell changed. Please log out and log back in for changes to take effect."
            grep dlesieur /etc/passwd
        fi
    else
        echo "zsh is not available in /etc/shells. Cannot change default shell."
        return 1
    fi
}

# Check if zsh is installed
if command -v zsh >/dev/null 2>&1; then
    echo "zsh is already installed."
else
    echo "Installing zsh..."
    sudo apt update && sudo apt install zsh -y

    if ! command -v zsh >/dev/null 2>&1; then
        echo "Failed to install zsh. Exiting."
        exit 1
    fi
fi

# Install Oh My Zsh if not already installed
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "Installing Oh My Zsh..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

    # The Oh My Zsh installer might change the shell automatically
    # If it doesn't, we'll change it ourselves
    if [[ "$SHELL" != *"zsh"* ]]; then
        change_default_shell
    fi
else
    echo "Oh My Zsh is already installed."
    # Change the shell if Oh My Zsh is already installed but shell isn't zsh
    if [[ "$SHELL" != *"zsh"* ]]; then
        change_default_shell
    fi
fi

echo "Configuration complete. Current shell: $SHELL"
echo "If your shell hasn't changed, please log out and log back in."
