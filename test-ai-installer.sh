#!/bin/bash
# test-ai-installer.sh - Test the AI-powered Arch installer ISO with QEMU

set -euo pipefail

# Configuration
ISO_PATH="${1:-}"
DISK_SIZE="${2:-30G}"
RAM="${3:-4096}"
CORES="${4:-4}"

# Find ISO if not specified
if [[ -z "$ISO_PATH" ]]; then
    ISO_PATH=$(ls -t arch-ai-installer-*.iso 2>/dev/null | head -n1)
    if [[ -z "$ISO_PATH" ]]; then
        echo "Error: No ISO found. Please build first or specify ISO path."
        echo "Usage: $0 [iso-path] [disk-size] [ram-mb] [cores]"
        exit 1
    fi
fi

if [[ ! -f "$ISO_PATH" ]]; then
    echo "Error: ISO not found: $ISO_PATH"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "       Testing AI-Powered Arch Linux Installer"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "ISO: $ISO_PATH"
echo "ISO Size: $(du -h "$ISO_PATH" | cut -f1)"
echo "Virtual Disk: $DISK_SIZE"
echo "RAM: ${RAM}MB"
echo "CPU Cores: $CORES"
echo ""

# Create virtual disk
DISK_IMG="arch-test-$(date +%Y%m%d-%H%M%S).qcow2"
echo "Creating virtual disk: $DISK_IMG ($DISK_SIZE)"
qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE"

# UEFI firmware
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS="/usr/share/OVMF/OVMF_VARS_4M.fd"
UEFI_ARGS=""

if [[ -f "$OVMF_CODE" ]]; then
    echo "Using UEFI boot"
    cp "$OVMF_VARS" "/tmp/OVMF_VARS_TEST.fd"
    UEFI_ARGS="-drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE -drive if=pflash,format=raw,file=/tmp/OVMF_VARS_TEST.fd"
else
    echo "Using BIOS boot (OVMF not found)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Starting QEMU VM..."
echo ""
echo "Access methods:"
echo "  • Console: This terminal window"
echo "  • VNC: Connect to localhost:5901"
echo "  • SSH: ssh -p 2222 root@localhost (once booted)"
echo "  • Monitor: telnet localhost 4444"
echo ""
echo "VM Controls:"
echo "  • Ctrl+Alt+G - Release mouse"
echo "  • Ctrl+Alt+F - Toggle fullscreen"
echo "  • Ctrl+Alt+2 - QEMU monitor"
echo "  • Ctrl+Alt+1 - Back to VM"
echo ""
echo "The AI installer should start automatically after boot."
echo "═══════════════════════════════════════════════════════════════"
echo ""
sleep 3

# Run QEMU
qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -smp "$CORES" \
    -m "$RAM" \
    -cdrom "$ISO_PATH" \
    -drive file="$DISK_IMG",format=qcow2,if=virtio \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -vga virtio \
    -display gtk,gl=on \
    -device virtio-rng-pci \
    -monitor telnet:127.0.0.1:4444,server,nowait \
    -vnc :1 \
    -serial stdio \
    $UEFI_ARGS

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "VM terminated."
echo ""
echo "Virtual disk saved as: $DISK_IMG"
echo "To restart with the same disk:"
echo "  qemu-system-x86_64 -enable-kvm -m $RAM -drive file=$DISK_IMG"
echo "═══════════════════════════════════════════════════════════════"