#!/bin/bash

# Create a test script
cat >~/test-apparmor.sh <<'EOF'
#!/bin/bash
echo "This is a test" > /tmp/apparmor-test.txt
echo "This should fail" > /root/apparmor-test.txt
EOF
chmod +x ~/test-apparmor.sh

# Create AppArmor profile for the test script
sudo tee /etc/apparmor.d/home.dlesieur.test-apparmor <<'EOF'
#include <tunables/global>

profile test-apparmor /home/dlesieur/test-apparmor.sh {
  #include <abstractions/base>
  
  /home/dlesieur/test-apparmor.sh r,
  /tmp/apparmor-test.txt w,
  # Explicitly deny write to /root
  deny /root/** w,
}
EOF

# Load the profile in enforce mode
sudo apparmor_parser -r /etc/apparmor.d/home.dlesieur.test-apparmor

# Check if it's loaded
sudo aa-status | grep test-apparmor
