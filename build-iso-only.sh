#!/bin/bash
# build-iso-only.sh - Build AI Installer ISO without writing to drive

set -euo pipefail

SSH_KEY="${1:-$(cat ~/.ssh/id_rsa.pub 2>/dev/null || cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo "")}"

if [[ -z "$SSH_KEY" ]]; then
    echo "Warning: No SSH key provided or found. You won't have SSH access."
    echo "Usage: $0 [ssh-public-key]"
    echo "Continuing without SSH key..."
    SSH_KEY="# No SSH key provided"
fi

# Check for Docker
if ! command -v docker &> /dev/null; then
    echo "Docker is required but not installed."
    echo "Install with: sudo pacman -S docker"
    echo "Then: sudo systemctl enable --now docker"
    echo "And add yourself to docker group: sudo usermod -aG docker $USER"
    exit 1
fi

# Check Docker daemon
if ! docker info &>/dev/null; then
    echo "Docker daemon is not running or you don't have permission."
    echo "Try: sudo systemctl start docker"
    echo "Or add yourself to docker group: sudo usermod -aG docker $USER"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════"
echo "     Building Arch Linux AI Installer ISO"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Execute the main build script with skip-write option
if [[ -f create-ai-installer-v2.sh ]]; then
    sudo ./create-ai-installer-v2.sh "" "$SSH_KEY" true
elif [[ -f create-ai-installer.sh ]]; then
    sudo ./create-ai-installer.sh "" "$SSH_KEY" true
else
    echo "Error: No build script found!"
    echo "Expected create-ai-installer-v2.sh or create-ai-installer.sh"
    exit 1
fi