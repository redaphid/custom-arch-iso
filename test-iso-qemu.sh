#!/bin/bash
# test-iso-qemu.sh - Test the AI Installer ISO with QEMU

set -euo pipefail

ISO_PATH="${1:-}"
UEFI_MODE="${2:-true}"
MEMORY="${3:-4096}"
CORES="${4:-2}"

if [[ -z "$ISO_PATH" ]]; then
    # Try to find the most recent ISO
    ISO_PATH=$(ls -t arch-ai-installer-*.iso 2>/dev/null | head -n1)
    if [[ -z "$ISO_PATH" ]]; then
        echo "Usage: $0 <iso-path> [uefi-mode] [memory-mb] [cores]"
        echo "  iso-path: Path to the ISO file"
        echo "  uefi-mode: true/false for UEFI boot (default: true)"
        echo "  memory-mb: RAM in MB (default: 4096)"
        echo "  cores: CPU cores (default: 2)"
        echo ""
        echo "No ISO found in current directory"
        exit 1
    fi
    echo "Found ISO: $ISO_PATH"
fi

if [[ ! -f "$ISO_PATH" ]]; then
    echo "Error: ISO file not found: $ISO_PATH"
    exit 1
fi

# Check for QEMU
if ! command -v qemu-system-x86_64 &> /dev/null; then
    echo "QEMU not found. Installing..."
    if command -v pacman &> /dev/null; then
        sudo pacman -S --noconfirm qemu-full
    elif command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y qemu-system-x86
    else
        echo "Please install QEMU manually"
        exit 1
    fi
fi

# Create a virtual disk for testing installation
DISK_IMG="test-disk.qcow2"
if [[ ! -f "$DISK_IMG" ]]; then
    echo "Creating 20GB virtual disk: $DISK_IMG"
    qemu-img create -f qcow2 "$DISK_IMG" 20G
fi

echo "═══════════════════════════════════════════════════════════"
echo "         QEMU Test Environment for AI Installer"
echo "═══════════════════════════════════════════════════════════"
echo "ISO: $ISO_PATH"
echo "Memory: ${MEMORY}MB"
echo "CPU Cores: $CORES"
echo "UEFI Mode: $UEFI_MODE"
echo "Virtual Disk: $DISK_IMG (20GB)"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Network: User mode (NAT)"
echo "VNC: localhost:5901 (use any VNC client to connect)"
echo "Monitor: localhost:4444 (telnet for QEMU monitor)"
echo ""
echo "Controls:"
echo "  • Ctrl+Alt+G - Release mouse grab"
echo "  • Ctrl+Alt+F - Fullscreen toggle"
echo "  • Ctrl+Alt+2 - QEMU Monitor"
echo "  • Ctrl+Alt+1 - Return to VM"
echo ""
echo "Starting VM in 3 seconds..."
sleep 3

# Build QEMU command
QEMU_CMD="qemu-system-x86_64"
QEMU_ARGS=(
    -enable-kvm
    -cpu host
    -smp cores="$CORES"
    -m "$MEMORY"
    -cdrom "$ISO_PATH"
    -drive file="$DISK_IMG",format=qcow2,if=virtio
    -netdev user,id=net0,hostfwd=tcp::2222-:22
    -device virtio-net-pci,netdev=net0
    -vga qxl
    -display sdl,gl=on
    -audio driver=pa,model=hda
    -device virtio-rng-pci
    -monitor telnet:127.0.0.1:4444,server,nowait
    -vnc :1
)

# Add UEFI firmware if requested
if [[ "$UEFI_MODE" == "true" ]]; then
    # Find OVMF firmware
    OVMF_CODE=""
    OVMF_VARS=""

    # Common OVMF locations
    for dir in /usr/share/edk2-ovmf /usr/share/ovmf /usr/share/OVMF /usr/share/edk2/ovmf; do
        if [[ -f "$dir/OVMF_CODE.fd" ]]; then
            OVMF_CODE="$dir/OVMF_CODE.fd"
            OVMF_VARS="$dir/OVMF_VARS.fd"
            break
        elif [[ -f "$dir/x64/OVMF_CODE.fd" ]]; then
            OVMF_CODE="$dir/x64/OVMF_CODE.fd"
            OVMF_VARS="$dir/x64/OVMF_VARS.fd"
            break
        fi
    done

    if [[ -n "$OVMF_CODE" ]]; then
        # Create a copy of VARS for this VM
        cp "$OVMF_VARS" /tmp/OVMF_VARS_TEST.fd
        QEMU_ARGS+=(
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
            -drive if=pflash,format=raw,file=/tmp/OVMF_VARS_TEST.fd
        )
        echo "Using UEFI firmware: $OVMF_CODE"
    else
        echo "Warning: OVMF UEFI firmware not found, falling back to BIOS"
        echo "Install with: sudo pacman -S edk2-ovmf"
    fi
fi

echo ""
echo "Launching QEMU..."
echo "Command: $QEMU_CMD ${QEMU_ARGS[@]}"
echo ""

# Run QEMU
"$QEMU_CMD" "${QEMU_ARGS[@]}"

echo ""
echo "VM terminated."