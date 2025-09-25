#!/bin/bash
# build-arch-ai-installer.sh - Build AI-powered Arch installer ISO using Docker

set -euo pipefail

DESTINATION_DRIVE="${1:-}"
SSH_KEY="${2:-}"

[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
[[ -z "$DESTINATION_DRIVE" ]] && { echo "Usage: $0 <drive> <ssh-key>"; exit 1; }
[[ -z "$SSH_KEY" ]] && { echo "Usage: $0 <drive> <ssh-key>"; exit 1; }

echo "This will DESTROY all data on $DESTINATION_DRIVE"
read -p "Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && exit 1

# Create build context
BUILD_DIR=$(mktemp -d)
cd "$BUILD_DIR"

# Create Dockerfile for archiso build environment
cat > Dockerfile << 'EOF'
FROM archlinux:latest
RUN pacman -Sy --noconfirm archiso
# Initialize pacman keyring in the container
RUN pacman-key --init && pacman-key --populate archlinux
WORKDIR /build
EOF

# Create build script
cat > build.sh << 'BUILDSCRIPT'
#!/bin/bash
set -euo pipefail

SSH_KEY="$1"

# Copy releng profile
cp -r /usr/share/archiso/configs/releng /build/profile
cd /build/profile

# Add our packages
cat >> packages.x86_64 << 'PACKAGES'

# Base tools
zellij
neovim
git
wget
base-devel
linux-headers
fish

# Python and pip
python
python-pip
python-setuptools
python-wheel

# Node.js for MCP servers
nodejs
npm

# Networking
networkmanager
net-tools

# System utils
htop
tmux
screen

# Build tools for AUR
cmake
make
gcc
PACKAGES

# Configure SSH
mkdir -p airootfs/root/.ssh
echo "$SSH_KEY" > airootfs/root/.ssh/authorized_keys
chmod 700 airootfs/root/.ssh
chmod 600 airootfs/root/.ssh/authorized_keys

# Enable SSH service
mkdir -p airootfs/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/sshd.service airootfs/etc/systemd/system/multi-user.target.wants/

# Enable NetworkManager
ln -sf /usr/lib/systemd/system/NetworkManager.service airootfs/etc/systemd/system/multi-user.target.wants/

# Create ollama installer script
cat > airootfs/usr/local/bin/install-ollama << 'OLLAMAINSTALL'
#!/bin/bash
set -e

echo "Installing Ollama..."

# Install ollama from official repos (CUDA version for NVIDIA)
pacman -S --noconfirm ollama-cuda

# Enable and start ollama service
systemctl enable ollama.service
systemctl start ollama.service

echo "Waiting for Ollama to start..."
sleep 5

# Pull the Qwen2.5 7B model (optimal for 4090)
echo "Downloading Qwen2.5 7B model (this may take a while)..."
ollama pull qwen2.5:7b

# Also get a smaller model for quick responses
echo "Downloading Qwen2.5 3B model for quick tasks..."
ollama pull qwen2.5:3b

# Get GPT-OSS model if available
echo "Attempting to download GPT-OSS model..."
ollama pull gpt-oss:20b || echo "GPT-OSS not available yet, using Qwen2.5"

echo "Ollama installed with models ready!"
ollama list
OLLAMAINSTALL
chmod +x airootfs/usr/local/bin/install-ollama

# Create fast-agent installer and configuration
cat > airootfs/usr/local/bin/install-fast-agent << 'FASTAGENTINSTALL'
#!/bin/bash
set -e

echo "Installing fast-agent MCP..."

# Install uv package manager
curl -LsSf https://astral.sh/uv/install.sh | sh
source $HOME/.cargo/env

# Install fast-agent
uv tool install fast-agent-mcp

# Install MCP servers
echo "Installing MCP servers..."
npm install -g @modelcontextprotocol/server-filesystem
npm install -g @modelcontextprotocol/server-fetch

# Create fast-agent configuration directory
mkdir -p /root/.config/fast-agent

# Create fastagent.config.yaml
cat > /root/.config/fast-agent/fastagent.config.yaml << 'CONFIG'
# FastAgent Configuration for Arch Installer

default_model: "generic.qwen2.5:7b"

logger:
  level: "info"
  type: "console"
  progress_display: true
  show_chat: true
  show_tools: true
  truncate_tools: false

mcp:
  servers:
    filesystem:
      transport: "stdio"
      command: "npx"
      args: ["@modelcontextprotocol/server-filesystem", "/"]
    fetch:
      transport: "stdio"
      command: "npx"
      args: ["@modelcontextprotocol/server-fetch"]
CONFIG

# Create agent script for Arch installation
cat > /root/arch-installer-agent.py << 'AGENT'
#!/usr/bin/env python3
import asyncio
from mcp_agent.core.fastagent import FastAgent

# Create the AI Arch Installer
fast = FastAgent("Arch Linux AI Installer")

@fast.agent(
    instruction="""You are an expert Arch Linux installation assistant. You help users:
    1. Partition drives (suggest GPT with EFI, root, and optionally home/swap)
    2. Format partitions (ext4, btrfs, or ZFS)
    3. Mount filesystems properly
    4. Install base system with pacstrap
    5. Generate fstab
    6. Configure system (locale, timezone, hostname, users)
    7. Install and configure bootloader (systemd-boot or GRUB)
    8. Set up networking
    9. Install essential packages

    Always explain what you're doing and ask for confirmation on destructive operations.
    Be helpful, thorough, and ensure the system will boot properly.
    You have full filesystem access and can execute any commands needed.""",
    servers=["filesystem", "fetch"]
)
async def main():
    async with fast.run(model="generic.qwen2.5:7b") as agent:
        print("\n" + "="*60)
        print("  ARCH LINUX AI-POWERED INSTALLER")
        print("="*60)
        print("\nHello! I'm your AI installation assistant.")
        print("I can help you install Arch Linux step by step.")
        print("\nI have full system access and can:")
        print("  • Partition and format drives")
        print("  • Install the base system")
        print("  • Configure your new installation")
        print("  • Set up bootloader and networking")
        print("\nLet's begin! What would you like to do?")
        print("(Tip: Start with 'Help me install Arch Linux on /dev/nvme0n1')")
        print("-"*60 + "\n")

        await agent.interactive()

if __name__ == "__main__":
    asyncio.run(main())
AGENT
chmod +x /root/arch-installer-agent.py

echo "Fast-agent installed successfully!"
echo "Configuration saved to /root/.config/fast-agent/"
FASTAGENTINSTALL
chmod +x airootfs/usr/local/bin/install-fast-agent

# Create auto-start service for AI assistant
cat > airootfs/etc/systemd/system/ai-installer.service << 'AISERVICE'
[Unit]
Description=AI-Powered Arch Linux Installer
After=multi-user.target ollama.service network.target
Wants=ollama.service

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.cargo/bin"
Environment="HOME=/root"
ExecStartPre=/bin/bash -c 'until systemctl is-active ollama.service; do sleep 2; done'
ExecStartPre=/bin/bash -c 'until ollama list | grep -q qwen; do sleep 5; done'
ExecStart=/usr/bin/python /root/arch-installer-agent.py
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
AISERVICE

# Create setup script that runs on first boot
cat > airootfs/root/setup-ai-installer.sh << 'SETUPSCRIPT'
#!/bin/bash
set -e

echo "Setting up AI-Powered Arch Linux Installer..."
echo "=========================================="

# Install ollama and models
/usr/local/bin/install-ollama

# Install fast-agent
/usr/local/bin/install-fast-agent

# Enable the AI installer service for next boot
systemctl enable ai-installer.service

echo ""
echo "=========================================="
echo "AI Installer setup complete!"
echo ""
echo "Run: python /root/arch-installer-agent.py"
echo "Or reboot to auto-start the AI assistant"
echo "=========================================="
SETUPSCRIPT
chmod +x airootfs/root/setup-ai-installer.sh

# Create auto-run script for first boot
cat > airootfs/etc/profile.d/first-boot.sh << 'FIRSTBOOT'
#!/bin/bash
if [ ! -f /root/.ai-setup-complete ]; then
    if [ "$USER" = "root" ]; then
        echo "First boot detected. Setting up AI installer..."
        /root/setup-ai-installer.sh
        touch /root/.ai-setup-complete
        echo ""
        echo "Starting AI Installer Assistant..."
        sleep 3
        python /root/arch-installer-agent.py
    fi
fi
FIRSTBOOT
chmod +x airootfs/etc/profile.d/first-boot.sh

# Create welcome message
cat > airootfs/etc/motd << 'MOTD'
==========================================================
    ARCH LINUX AI-POWERED INSTALLER
==========================================================
Welcome! This system will automatically set up an AI
assistant to help you install Arch Linux.

On first login, the system will:
1. Install Ollama with Qwen2.5 model
2. Install fast-agent MCP framework
3. Launch the AI installation assistant

The AI assistant has full system access and can:
• Partition and format drives
• Install Arch Linux base system
• Configure bootloader and networking
• Guide you through the entire installation

SSH is enabled with your key for remote access.
==========================================================
MOTD

# Add auto-login for root on tty1
mkdir -p airootfs/etc/systemd/system/getty@tty1.service.d
cat > airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin root %I $TERM
AUTOLOGIN

# Build ISO
mkarchiso -v -w /tmp/work -o /output /build/profile
BUILDSCRIPT

chmod +x build.sh

# Build and run
echo "Building Docker image..."
docker build -t archiso-builder .

echo "Running archiso build in container..."
docker run --rm --privileged \
    -v "$BUILD_DIR:/output" \
    archiso-builder \
    /output/build.sh "$SSH_KEY"

# Find and write ISO
ISO=$(find . -name "*.iso" | head -n1)
if [[ -z "$ISO" ]]; then
    echo "Error: No ISO file generated!"
    exit 1
fi

echo "Writing $ISO to $DESTINATION_DRIVE..."
dd if="$ISO" of="$DESTINATION_DRIVE" bs=4M status=progress oflag=direct

rm -rf "$BUILD_DIR"
echo ""
echo "==============================================="
echo "Success! AI-Powered Arch Installer ISO created"
echo "==============================================="
echo ""
echo "Boot from $DESTINATION_DRIVE and the system will:"
echo "1. Auto-login as root"
echo "2. Install Ollama with Qwen2.5 model"
echo "3. Install fast-agent MCP framework"
echo "4. Launch AI installation assistant"
echo ""
echo "The AI will guide you through the entire"
echo "Arch Linux installation process!"
echo "==============================================="