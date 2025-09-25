#!/bin/bash
# Test ISO with QEMU monitor and VNC for screenshot capture

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
echo "Starting QEMU with monitor and VNC..."

# Create named pipes for QEMU monitor
MONITOR_IN="/tmp/qemu-monitor-in-$$"
MONITOR_OUT="/tmp/qemu-monitor-out-$$"
mkfifo "$MONITOR_IN" "$MONITOR_OUT"

# Start QEMU in background with:
# - Monitor on stdio for control
# - VNC server for screenshots
# - Serial console to file
SERIAL_LOG="/tmp/qemu-serial-$(date +%Y%m%d-%H%M%S).log"

echo "Starting QEMU..."
qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -m 8192 \
    -smp 4 \
    -drive file="$ISO",media=cdrom,readonly=on \
    -boot d \
    -vnc :1 \
    -serial file:"$SERIAL_LOG" \
    -monitor pipe:"$MONITOR_IN":"$MONITOR_OUT" \
    -display none \
    &

QEMU_PID=$!
echo "QEMU PID: $QEMU_PID"

# Function to send monitor commands
send_monitor() {
    echo "$1" > "$MONITOR_IN"
    sleep 0.5
}

# Wait for boot
echo "Waiting for system to boot (30 seconds)..."
sleep 30

# Take a screenshot
SCREENSHOT="/tmp/qemu-screenshot-$(date +%Y%m%d-%H%M%S).ppm"
echo "Taking screenshot to $SCREENSHOT..."
send_monitor "screendump $SCREENSHOT"
sleep 2

# Convert PPM to PNG if ImageMagick is available
if command -v convert &> /dev/null; then
    PNG_FILE="${SCREENSHOT%.ppm}.png"
    convert "$SCREENSHOT" "$PNG_FILE"
    echo "Screenshot saved as: $PNG_FILE"
fi

# Send some keystrokes to interact
echo "Sending Enter key to interact with console..."
send_monitor "sendkey ret"
sleep 2

# Try to type a command
echo "Typing 'ai-installer' command..."
for char in a i - i n s t a l l e r; do
    send_monitor "sendkey $char"
    sleep 0.1
done
send_monitor "sendkey ret"

# Wait a bit more
sleep 5

# Take another screenshot
SCREENSHOT2="/tmp/qemu-screenshot2-$(date +%Y%m%d-%H%M%S).ppm"
echo "Taking second screenshot to $SCREENSHOT2..."
send_monitor "screendump $SCREENSHOT2"

# Get VM info
echo "Getting VM info..."
send_monitor "info status"
cat "$MONITOR_OUT" 2>/dev/null | head -20

# Stop QEMU
echo "Stopping QEMU..."
send_monitor "quit"
sleep 2
kill $QEMU_PID 2>/dev/null

# Clean up pipes
rm -f "$MONITOR_IN" "$MONITOR_OUT"

# Analyze serial log
echo ""
echo "Analyzing serial output..."
if [ -f "$SERIAL_LOG" ]; then
    echo "Serial log: $SERIAL_LOG"
    # Check for errors
    grep -i "error\|fail\|not found" "$SERIAL_LOG" | head -10
else
    echo "No serial output captured"
fi

echo ""
echo "Test completed. Check screenshots and logs for details."