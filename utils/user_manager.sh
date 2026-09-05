#!/bin/bash

source ./color_scheme.sh
# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# Display header
display_header() {
    clear
    echo -e "${BLUE}=======================================${NC}"
    echo -e "${BLUE}      USER MANAGEMENT UTILITY         ${NC}"
    echo -e "${BLUE}=======================================${NC}"
    echo ""
}

# List all users with details
list_users() {
    display_header
    echo -e "${YELLOW}SYSTEM USERS:${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"
    printf "%-15s %-10s %-10s %-20s\n" "USERNAME" "USER ID" "GROUP" "HOME DIRECTORY"
    echo -e "${YELLOW}-----------------------------------------${NC}"

    # List users with UID >= 1000 (normal users, not system users)
    awk -F':' '$3 >= 1000 && $3 != 65534 {print $1,$3,$4,$6}' /etc/passwd |
        while read username uid gid homedir; do
            group=$(getent group $gid | cut -d: -f1)
            printf "%-15s %-10s %-10s %-20s\n" "$username" "$uid" "$group" "$homedir"
        done

    echo ""
    read -p "Press Enter to continue..."
}

# Create a new user
create_user() {
    display_header
    echo -e "${GREEN}CREATE NEW USER${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"

    read -p "Enter username: " username

    # Check if user already exists
    if id "$username" &>/dev/null; then
        echo -e "${RED}Error: User $username already exists!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Enter full name: " fullname

    # Create user
    useradd -m -c "$fullname" "$username"

    # Set password
    echo -e "${YELLOW}Setting password for $username${NC}"
    passwd $username

    # Ask if user should be added to sudo group
    read -p "Add user to sudo group? (y/n): " add_sudo
    if [[ $add_sudo == "y" || $add_sudo == "Y" ]]; then
        usermod -aG sudo "$username"
        echo -e "${GREEN}User $username added to sudo group${NC}"
    fi

    echo -e "${GREEN}User $username created successfully!${NC}"
    read -p "Press Enter to continue..."
}

# Delete an existing user
delete_user() {
    display_header
    echo -e "${RED}DELETE USER${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"

    read -p "Enter username to delete: " username

    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo -e "${RED}Error: User $username does not exist!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Delete home directory? (y/n): " del_home

    if [[ $del_home == "y" || $del_home == "Y" ]]; then
        userdel -r "$username"
        echo -e "${GREEN}User $username and home directory deleted.${NC}"
    else
        userdel "$username"
        echo -e "${GREEN}User $username deleted. Home directory preserved.${NC}"
    fi

    read -p "Press Enter to continue..."
}

# Modify user properties
modify_user() {
    display_header
    echo -e "${BLUE}MODIFY USER${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"

    read -p "Enter username to modify: " username

    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo -e "${RED}Error: User $username does not exist!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo -e "${YELLOW}What would you like to modify?${NC}"
    echo "1. Change password"
    echo "2. Add to group"
    echo "3. Change shell"
    echo "4. Lock/unlock account"
    echo "5. Go back"

    read -p "Select option [1-5]: " option

    case $option in
    1) # Change password
        passwd "$username"
        echo -e "${GREEN}Password changed for $username${NC}"
        ;;
    2) # Add to group
        read -p "Enter group name: " groupname

        # Check if group exists
        if ! getent group "$groupname" &>/dev/null; then
            read -p "Group doesn't exist. Create it? (y/n): " create_group
            if [[ $create_group == "y" || $create_group == "Y" ]]; then
                groupadd "$groupname"
            else
                echo -e "${RED}Operation canceled.${NC}"
                read -p "Press Enter to continue..."
                return
            fi
        fi

        usermod -aG "$groupname" "$username"
        echo -e "${GREEN}User $username added to group $groupname${NC}"
        ;;
    3) # Change shell
        echo "Available shells:"
        cat /etc/shells
        read -p "Enter new shell path: " shellpath

        # Verify shell exists
        if grep -q "^$shellpath$" /etc/shells; then
            usermod -s "$shellpath" "$username"
            echo -e "${GREEN}Shell changed for $username${NC}"
        else
            echo -e "${RED}Invalid shell. Please enter a path from /etc/shells${NC}"
        fi
        ;;
    4) # Lock/unlock account
        echo "1. Lock account"
        echo "2. Unlock account"
        read -p "Select option [1-2]: " lock_option

        if [ "$lock_option" == "1" ]; then
            passwd -l "$username"
            echo -e "${GREEN}Account locked for $username${NC}"
        elif [ "$lock_option" == "2" ]; then
            passwd -u "$username"
            echo -e "${GREEN}Account unlocked for $username${NC}"
        else
            echo -e "${RED}Invalid option${NC}"
        fi
        ;;
    5) # Go back
        return
        ;;
    *)
        echo -e "${RED}Invalid option${NC}"
        ;;
    esac

    read -p "Press Enter to continue..."
}

# Check detailed user information
user_info() {
    display_header
    echo -e "${BLUE}USER INFORMATION${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"

    read -p "Enter username: " username

    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo -e "${RED}Error: User $username does not exist!${NC}"
        read -p "Press Enter to continue..."
        return
    fi

    echo -e "${YELLOW}Basic Information:${NC}"
    id "$username"

    echo -e "\n${YELLOW}Group Memberships:${NC}"
    groups "$username"

    echo -e "\n${YELLOW}Last Login:${NC}"
    lastlog -u "$username"

    echo -e "\n${YELLOW}Account Aging Information:${NC}"
    chage -l "$username"

    echo -e "\n${YELLOW}User's Home Directory:${NC}"
    eval echo ~"$username"

    echo -e "\n${YELLOW}Is user in sudo group?${NC}"
    if groups "$username" | grep -q '\bsudo\b'; then
        echo -e "${GREEN}Yes, $username has sudo privileges${NC}"
    else
        echo -e "${RED}No, $username does not have sudo privileges${NC}"
    fi

    read -p "Press Enter to continue..."
}

# Show password policy
show_password_policy() {
    display_header
    echo -e "${BLUE}PASSWORD POLICY${NC}"
    echo -e "${YELLOW}-----------------------------------------${NC}"

    if [ -f /etc/pam.d/common-password ]; then
        echo -e "${YELLOW}PAM Password Configuration:${NC}"
        grep -v "^#" /etc/pam.d/common-password | grep -v "^$"
    fi

    if [ -f /etc/login.defs ]; then
        echo -e "\n${YELLOW}Password Aging Policy:${NC}"
        grep "^PASS_" /etc/login.defs
    fi

    if [ -f /etc/security/pwquality.conf ]; then
        echo -e "\n${YELLOW}Password Quality Requirements:${NC}"
        grep -v "^#" /etc/security/pwquality.conf | grep -v "^$"
    fi

    read -p "Press Enter to continue..."
}

# Main menu
while true; do
    display_header
    echo "1. List all users"
    echo "2. Create new user"
    echo "3. Delete user"
    echo "4. Modify user"
    echo "5. Show user information"
    echo "6. Show password policy"
    echo "7. Exit"
    echo ""
    read -p "Select an option [1-7]: " choice

    case $choice in
    1) list_users ;;
    2) create_user ;;
    3) delete_user ;;
    4) modify_user ;;
    5) user_info ;;
    6) show_password_policy ;;
    7)
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid option. Please try again.${NC}"
        sleep 1
        ;;
    esac
done
