#!/bin/bash
# Test the AI Installer ISO with QEMU

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_DIR="$SCRIPT_DIR/isos"

# Check if an ISO was specified as argument
if [ -n "$1" ]; then
    if [ -f "$1" ]; then
        ISO="$1"
    else
        echo "Error: Specified ISO file not found: $1"
        exit 1
    fi
else
    # Find the most recent ISO in the isos/ directory
    if [ -d "$ISO_DIR" ]; then
        ISO=$(ls -t "$ISO_DIR"/*.iso 2>/dev/null | head -n1)
    fi

    # If no ISO in isos/, try current directory
    if [ -z "$ISO" ]; then
        ISO=$(ls -t *.iso 2>/dev/null | head -n1)
    fi

    # Last resort: try to find in temp directories
    if [ -z "$ISO" ]; then
        ISO=$(find /tmp -name "archlinux-*.iso" -type f 2>/dev/null | head -n1)
        if [ -n "$ISO" ]; then
            echo "Found ISO in temp: $ISO"
            # Copy it to isos directory
            mkdir -p "$ISO_DIR"
            ISO_DATE=$(date +%Y%m%d-%H%M%S)
            NEW_ISO="$ISO_DIR/arch-ai-installer-${ISO_DATE}.iso"
            echo "Copying to: $NEW_ISO"
            cp "$ISO" "$NEW_ISO"
            ISO="$NEW_ISO"
        fi
    fi
fi

if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
    echo "Error: No ISO file found"
    echo ""
    echo "Please run ./docker-build.sh first to create an ISO"
    echo "Or specify an ISO file: $0 <path-to-iso>"
    echo ""
    echo "Checked locations:"
    echo "  - $ISO_DIR/*.iso"
    echo "  - ./*.iso"
    echo "  - /tmp/archlinux-*.iso"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════"
echo "           Testing Arch AI Installer ISO"
echo "═══════════════════════════════════════════════════════════"
echo "ISO: $ISO"
echo "Size: $(du -h "$ISO" | cut -f1)"
echo ""
echo "Starting QEMU..."
echo "Once booted, the AI assistant should start automatically!"
echo ""
echo "Controls:"
echo "  • Ctrl+Alt+G - Release mouse grab"
echo "  • Ctrl+C here - Stop QEMU"
echo "═══════════════════════════════════════════════════════════"

# Run QEMU with the ISO
qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -m 8192 \
    -smp 4 \
    -drive file="$ISO",media=cdrom,readonly=on \
    -boot d \
    -vga virtio \
    -display gtk \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    -device qemu-xhci \
    -device usb-kbd \
    -device usb-tablet