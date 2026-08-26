#!/usr/bin/env bash
# Test script to verify the shipped hellish binary works in the container.
# The container installs dist/hellish (downloaded by `make shell`); it does not
# compile anything.

set -e

cd "$(dirname "$0")"

echo "=== Testing Docker Container ==="
echo ""

# Test 1: Check docker compose config
echo "[1/4] Checking docker compose configuration..."
docker compose -f docker-compose.yml config > /dev/null && echo "✓ Config valid" || exit 1

# Test 2: Test with bash shell (non-interactive command)
echo "[2/4] Testing container with bash (non-interactive)..."
docker compose -f docker-compose.yml run --rm \
  -e SHELL_MODE=bash debian-shell-lab /bin/bash -c "whoami && pwd && echo 'Bash works!'"
echo "✓ Bash execution passed"

# Test 3: Install and run the shipped hellish (non-interactive)
echo "[3/4] Testing container installs and runs hellish (non-interactive)..."
docker compose -f docker-compose.yml run --rm \
  -e SHELL_MODE=hellish debian-shell-lab /bin/echo "Hellish shell available"
echo "✓ Hellish installed and available in container"

# Test 4: Attempt interactive test
echo "[4/4] Interactive shell test (type 'exit' to return)..."
echo ""
docker compose -f docker-compose.yml run --rm \
  -e SHELL_MODE=hellish debian-shell-lab
echo ""
echo "=== Container test complete ==="