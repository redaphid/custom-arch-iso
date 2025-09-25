#!/bin/bash
# Test the AI Installer ISO headless with serial output capture

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_DIR="$SCRIPT_DIR/isos"

# Find the most recent ISO
if [ -d "$ISO_DIR" ]; then
    ISO=$(ls -t "$ISO_DIR"/*.iso 2>/dev/null | head -n1)
fi

if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
    echo "Error: No ISO file found in $ISO_DIR"
    exit 1
fi

echo "Testing ISO: $ISO"
echo "Starting QEMU with serial console..."
echo "=" | head -c 60
echo ""

# Create a log file for the output
LOG_FILE="/tmp/qemu-boot-$(date +%Y%m%d-%H%M%S).log"
echo "Logging to: $LOG_FILE"

# Run QEMU with serial console output
# -nographic: No GUI
# -serial mon:stdio: Multiplex monitor and serial to stdio
# The ISO needs to be configured for serial console
timeout 60 qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -m 8192 \
    -smp 4 \
    -drive file="$ISO",media=cdrom,readonly=on \
    -boot d \
    -nographic \
    -serial mon:stdio \
    2>&1 | tee "$LOG_FILE"

echo ""
echo "=" | head -c 60
echo ""
echo "Boot test completed. Output saved to: $LOG_FILE"
echo ""
echo "Analyzing boot log for errors..."
echo ""

# Check for common errors
if grep -q "Failed to start" "$LOG_FILE"; then
    echo "❌ Found service failures:"
    grep "Failed to start" "$LOG_FILE" | head -5
fi

if grep -q "No such file or directory" "$LOG_FILE"; then
    echo "❌ Found missing files:"
    grep "No such file or directory" "$LOG_FILE" | head -5
fi

if grep -q "command not found" "$LOG_FILE"; then
    echo "❌ Found missing commands:"
    grep "command not found" "$LOG_FILE" | head -5
fi

if grep -q "ModuleNotFoundError\|ImportError" "$LOG_FILE"; then
    echo "❌ Found Python import errors:"
    grep -A2 "ModuleNotFoundError\|ImportError" "$LOG_FILE" | head -10
fi

if grep -q "ai-installer" "$LOG_FILE"; then
    echo "✓ Found ai-installer references"
fi

if grep -q "ARCH LINUX AI-POWERED INSTALLER" "$LOG_FILE"; then
    echo "✓ AI Installer started"
fi

echo ""
echo "Full log available at: $LOG_FILE"