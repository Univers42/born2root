#!/bin/bash
# Create registry bypass file for Windows 11 TPM check
cat >"$HOME/win11_bypass.reg" <<'EOL'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig]
"BypassTPMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
"BypassRAMCheck"=dword:00000001
EOL

echo "Created TPM bypass registry file at $HOME/win11_bypass.reg"
echo "During Windows 11 installation:"
echo "1. When you reach the 'This PC can't run Windows 11' screen, press Shift+F10"
echo "2. Type 'regedit' and press Enter"
echo "3. Import the registry file from the shared folder"
echo "4. Close regedit and continue with installation"
