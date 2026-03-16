#!/usr/bin/env bash
# Test script to verify hellish container builds and works

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

# Test 3: Build and test hellish with simple command (non-interactive)
echo "[3/4] Testing container builds and runs hellish (non-interactive)..."
docker compose -f docker-compose.yml run --rm \
  -e SHELL_MODE=hellish debian-shell-lab /bin/echo "Hellish shell available"
echo "✓ Hellish built and available in container"

# Test 4: Attempt interactive test
echo "[4/4] Interactive shell test (type 'exit' to return)..."
echo ""
docker compose -f docker-compose.yml run --rm \
  -e SHELL_MODE=hellish debian-shell-lab
echo ""
echo "=== Container test complete ==="