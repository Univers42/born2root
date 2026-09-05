#!/bin/bash
# Born2beRoot Password Policy Fix

# Text colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== FIXING PASSWORD POLICY FOR BORN2BEROOT ===${NC}"

# 1. Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Run with sudo."
    exit 1
fi

# 2. Backup current configuration
echo -e "${YELLOW}Creating backups of configuration files...${NC}"
cp /etc/login.defs /etc/login.defs.backup
cp /etc/pam.d/common-password /etc/pam.d/common-password.backup

# 3. Configure password expiration policy
echo -e "${YELLOW}Setting password expiration policy...${NC}"
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   30/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   2/' /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   7/' /etc/login.defs

# 4. Configure password complexity
echo -e "${YELLOW}Setting password complexity requirements...${NC}"
if ! grep -q "pam_pwquality.so" /etc/pam.d/common-password; then
    echo "Installing libpam-pwquality..."
    apt-get install -y libpam-pwquality
fi

# Update configuration if line exists
if grep -q "pam_pwquality.so" /etc/pam.d/common-password; then
    sed -i '/pam_pwquality.so/c\password        requisite                       pam_pwquality.so retry=3 minlen=10 ucredit=-1 dcredit=-1 maxrepeat=3 reject_username difok=7 enforce_for_root' /etc/pam.d/common-password
else
    # Add configuration if line doesn't exist
    sed -i '/pam_unix.so/i password        requisite                       pam_pwquality.so retry=3 minlen=10 ucredit=-1 dcredit=-1 maxrepeat=3 reject_username difok=7 enforce_for_root' /etc/pam.d/common-password
fi

# 5. Apply changes to existing users
echo -e "${YELLOW}Applying policy to user accounts...${NC}"
for user in $(grep "/bin/bash" /etc/passwd | cut -d: -f1); do
    chage -M 30 -m 2 -W 7 $user
    echo "Updated policy for user: $user"
done

# 6. Verify configuration
echo -e "${GREEN}Password policy updated successfully!${NC}"
echo -e "${YELLOW}Current settings for your user:${NC}"
chage -l dlesieur

echo -e "${BLUE}=== PASSWORD POLICY FIX COMPLETE ===${NC}"
echo "Remember to test by creating a new password that meets the requirements."
