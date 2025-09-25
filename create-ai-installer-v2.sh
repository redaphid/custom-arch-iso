#!/bin/bash
# build-arch-ai-installer-v2.sh - Build AI-powered Arch installer ISO using Docker

set -euo pipefail

DESTINATION_DRIVE="${1:-}"
SSH_KEY="${2:-}"
SKIP_WRITE="${3:-false}"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

if [[ -z "$SSH_KEY" ]]; then
    echo "Usage: $0 [destination_drive] <ssh-key> [skip-write]"
    echo "  destination_drive: Device to write ISO to (optional if skip-write=true)"
    echo "  ssh-key: Your SSH public key for remote access"
    echo "  skip-write: Set to 'true' to only build ISO without writing to drive"
    exit 1
fi

if [[ "$SKIP_WRITE" != "true" && -z "$DESTINATION_DRIVE" ]]; then
    echo "Error: destination_drive required when not skipping write"
    exit 1
fi

if [[ "$SKIP_WRITE" != "true" ]]; then
    echo "WARNING: This will DESTROY all data on $DESTINATION_DRIVE"
    read -p "Continue? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && exit 1
fi

# Create build context
BUILD_DIR=$(mktemp -d)
echo "Build directory: $BUILD_DIR"
cd "$BUILD_DIR"

# Create Dockerfile for archiso build environment
cat > Dockerfile << 'EOF'
FROM archlinux:latest
RUN pacman -Sy --noconfirm archiso
RUN pacman-key --init && pacman-key --populate archlinux
WORKDIR /build
EOF

# Create the main build script
cat > build.sh << 'BUILDSCRIPT'
#!/bin/bash
set -euo pipefail

SSH_KEY="$1"

# Copy releng profile
cp -r /usr/share/archiso/configs/releng /build/profile
cd /build/profile

# Customize packages list
cat >> packages.x86_64 << 'PACKAGES'

# Terminal and shell
zellij
tmux
screen
fish
zsh

# Editors
neovim
nano
vim

# Development
git
base-devel
cmake
gcc
make
linux-headers

# Python
python
python-pip
python-setuptools
python-wheel
python-virtualenv

# Node.js and npm
nodejs
npm

# Network tools
networkmanager
net-tools
wget
curl
openssh

# System utilities
htop
btop
ncdu
tree
jq
ripgrep
fd

# Disk tools
parted
gptfdisk
dosfstools
e2fsprogs
btrfs-progs
ntfs-3g

# Archive tools
zip
unzip
p7zip

# For ollama
go
PACKAGES

# Setup SSH
mkdir -p airootfs/root/.ssh
echo "$SSH_KEY" > airootfs/root/.ssh/authorized_keys
chmod 700 airootfs/root/.ssh
chmod 600 airootfs/root/.ssh/authorized_keys

# Enable critical services
mkdir -p airootfs/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/sshd.service airootfs/etc/systemd/system/multi-user.target.wants/
ln -sf /usr/lib/systemd/system/NetworkManager.service airootfs/etc/systemd/system/multi-user.target.wants/
ln -sf /usr/lib/systemd/system/systemd-networkd.service airootfs/etc/systemd/system/multi-user.target.wants/
ln -sf /usr/lib/systemd/system/systemd-resolved.service airootfs/etc/systemd/system/multi-user.target.wants/

# Configure network for DHCP
mkdir -p airootfs/etc/systemd/network
cat > airootfs/etc/systemd/network/20-wired.network << 'NETWORK'
[Match]
Name=en*
Name=eth*

[Network]
DHCP=yes
NETWORK

# Create ollama installation and service
mkdir -p airootfs/usr/local/bin
cat > airootfs/usr/local/bin/setup-ollama << 'OLLAMASETUP'
#!/bin/bash
set -e

echo "==================================="
echo "Installing Ollama..."
echo "==================================="

# Check if already installed
if command -v ollama &> /dev/null; then
    echo "Ollama already installed"
else
    # Install ollama binary directly
    curl -fsSL https://ollama.ai/install.sh | sh
fi

# Create ollama user and group if they don't exist
if ! id -u ollama &>/dev/null; then
    useradd -r -s /bin/false -m -d /usr/share/ollama ollama
fi

# Create systemd service
cat > /etc/systemd/system/ollama.service << 'SERVICE'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=0.0.0.0"
Environment="HOME=/usr/share/ollama"

[Install]
WantedBy=multi-user.target
SERVICE

# Reload systemd and start ollama
systemctl daemon-reload
systemctl enable ollama.service
systemctl start ollama.service

echo "Waiting for Ollama to start..."
for i in {1..30}; do
    if curl -s http://localhost:11434/api/tags &>/dev/null; then
        echo "Ollama is running!"
        break
    fi
    sleep 1
done

# Pull models
echo "Pulling Qwen2.5 7B model..."
ollama pull qwen2.5:7b || ollama pull qwen2.5:latest || echo "Failed to pull Qwen2.5 7B"

echo "Pulling smaller Qwen2.5 3B model..."
ollama pull qwen2.5:3b || echo "Failed to pull Qwen2.5 3B"

# Try to get DeepSeek Coder for coding tasks
echo "Attempting to pull DeepSeek Coder..."
ollama pull deepseek-coder:6.7b || echo "DeepSeek Coder not available"

echo "Available models:"
ollama list

echo "Ollama setup complete!"
OLLAMASETUP
chmod +x airootfs/usr/local/bin/setup-ollama

# Create fast-agent setup
cat > airootfs/usr/local/bin/setup-fast-agent << 'FASTAGENTSETUP'
#!/bin/bash
set -e

echo "==================================="
echo "Installing Fast-Agent MCP..."
echo "==================================="

# Install pip packages needed
pip install --break-system-packages fast-agent-mcp mcp

# Install MCP servers
echo "Installing MCP servers..."
npm install -g @modelcontextprotocol/server-filesystem @modelcontextprotocol/server-fetch

# Create configuration directory
mkdir -p /root/.config/fast-agent

# Create the fast-agent configuration
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
      args:
        - "@modelcontextprotocol/server-filesystem"
        - "/"
    fetch:
      transport: "stdio"
      command: "npx"
      args:
        - "@modelcontextprotocol/server-fetch"
CONFIG

echo "Fast-agent MCP installed!"
FASTAGENTSETUP
chmod +x airootfs/usr/local/bin/setup-fast-agent

# Create the main AI installer agent
cat > airootfs/root/ai-installer.py << 'AIAGENT'
#!/usr/bin/env python3
"""
Arch Linux AI Installation Assistant
Powered by Ollama and Fast-Agent MCP
"""

import asyncio
import os
import sys

# Ensure we can import fast-agent
sys.path.insert(0, '/usr/lib/python3.12/site-packages')

try:
    from mcp_agent.core.fastagent import FastAgent
except ImportError:
    print("Fast-agent not found. Please run: /usr/local/bin/setup-fast-agent")
    sys.exit(1)

# Create the installer agent
fast = FastAgent("Arch Linux AI Installer")

INSTALLER_PROMPT = """You are an expert Arch Linux installation assistant with full system access.

Your capabilities:
- Full filesystem access to read/write any file
- Execute any system command via tools
- Guide users through the entire installation process
- Explain each step clearly

Installation tasks you can help with:
1. **Disk Preparation**:
   - List available disks (lsblk, fdisk -l)
   - Partition disks (fdisk, gdisk, parted)
   - Format partitions (mkfs.ext4, mkfs.fat, mkfs.btrfs)
   - Setup encryption (cryptsetup)
   - Configure LVM or RAID if needed

2. **Base System Installation**:
   - Mount partitions correctly
   - Use pacstrap to install base system
   - Generate fstab
   - Chroot into new system

3. **System Configuration**:
   - Set timezone and locale
   - Configure hostname and hosts file
   - Set up users and passwords
   - Configure sudo

4. **Boot Configuration**:
   - Install and configure bootloader (GRUB, systemd-boot, rEFInd)
   - Configure kernel parameters
   - Setup initramfs

5. **Network Setup**:
   - Configure NetworkManager or systemd-networkd
   - Setup wireless if needed

6. **Post-Installation**:
   - Install essential packages
   - Configure systemd services
   - Setup AUR helper if desired
   - Install desktop environment if requested

IMPORTANT GUIDELINES:
- Always explain what you're about to do
- Ask for confirmation before destructive operations
- Provide clear error messages if something fails
- Suggest best practices and common configurations
- Be patient and thorough

Start by asking the user about their target disk and desired configuration."""

@fast.agent(
    instruction=INSTALLER_PROMPT,
    servers=["filesystem", "fetch"]
)
async def main():
    """Main installation assistant entry point"""

    # Try to connect with the ollama model
    model = os.getenv("AI_MODEL", "generic.qwen2.5:7b")

    print("\n" + "="*70)
    print("       ARCH LINUX AI-POWERED INSTALLATION ASSISTANT")
    print("="*70)
    print(f"\n✓ Model: {model}")
    print("✓ Full system access enabled")
    print("✓ MCP servers: filesystem, fetch")
    print("\n" + "-"*70)
    print("\nHello! I'm your AI installation assistant.")
    print("I'll help you install Arch Linux step by step.")
    print("\nI can:")
    print("  • Partition and format your drives")
    print("  • Install the Arch base system")
    print("  • Configure bootloader and networking")
    print("  • Set up users and system settings")
    print("  • Install desktop environments")
    print("\nLet's start! Tell me:")
    print("  1. Which disk you want to install to (run 'lsblk' to see options)")
    print("  2. Whether you want UEFI or BIOS boot")
    print("  3. Your preferred filesystem (ext4, btrfs, zfs)")
    print("\n" + "="*70 + "\n")

    try:
        async with fast.run(model=model) as agent:
            await agent.interactive()
    except KeyboardInterrupt:
        print("\n\nInstallation assistant terminated by user.")
    except Exception as e:
        print(f"\n\nError: {e}")
        print("You may need to run setup scripts first:")
        print("  1. /usr/local/bin/setup-ollama")
        print("  2. /usr/local/bin/setup-fast-agent")

if __name__ == "__main__":
    asyncio.run(main())
AIAGENT
chmod +x airootfs/root/ai-installer.py

# Create a comprehensive first-boot setup script
cat > airootfs/root/first-boot-setup.sh << 'FIRSTBOOT'
#!/bin/bash

echo ""
echo "============================================"
echo "   ARCH AI INSTALLER - FIRST BOOT SETUP"
echo "============================================"
echo ""

# Check network connectivity
echo "Checking network connection..."
if ping -c 1 archlinux.org &>/dev/null; then
    echo "✓ Network connected"
else
    echo "⚠ No network connection. Trying to establish..."
    systemctl restart NetworkManager
    sleep 5
fi

# Setup ollama
echo ""
echo "Step 1/3: Setting up Ollama..."
echo "--------------------------------"
if /usr/local/bin/setup-ollama; then
    echo "✓ Ollama ready"
else
    echo "⚠ Ollama setup had issues, continuing..."
fi

# Setup fast-agent
echo ""
echo "Step 2/3: Setting up Fast-Agent..."
echo "--------------------------------"
if /usr/local/bin/setup-fast-agent; then
    echo "✓ Fast-Agent ready"
else
    echo "⚠ Fast-Agent setup had issues"
fi

# Mark setup complete
touch /root/.first-boot-complete

echo ""
echo "Step 3/3: Launching AI Assistant..."
echo "--------------------------------"
sleep 2

# Launch the AI installer
exec python /root/ai-installer.py
FIRSTBOOT
chmod +x airootfs/root/first-boot-setup.sh

# Configure automatic first-boot execution
cat > airootfs/root/.bash_profile << 'BASHPROFILE'
# Auto-run first boot setup if not completed
if [ ! -f /root/.first-boot-complete ]; then
    /root/first-boot-setup.sh
fi
BASHPROFILE

# Create a fallback manual start script
cat > airootfs/usr/local/bin/ai-install << 'AIINSTALL'
#!/bin/bash
python /root/ai-installer.py
AIINSTALL
chmod +x airootfs/usr/local/bin/ai-install

# Set up auto-login for root on tty1
mkdir -p airootfs/etc/systemd/system/getty@tty1.service.d
cat > airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin root %I $TERM
AUTOLOGIN

# Create helpful MOTD
cat > airootfs/etc/motd << 'MOTD'
╔════════════════════════════════════════════════════════════╗
║          ARCH LINUX AI-POWERED INSTALLER ISO              ║
╠════════════════════════════════════════════════════════════╣
║                                                            ║
║  This system features an AI assistant that will help you  ║
║  install Arch Linux interactively.                        ║
║                                                            ║
║  On first boot, the system will:                          ║
║   1. Install Ollama with Qwen2.5 language model          ║
║   2. Setup Fast-Agent MCP framework                       ║
║   3. Launch the AI installation assistant                 ║
║                                                            ║
║  The AI has full system access to:                        ║
║   • Partition and format drives                           ║
║   • Install base system and packages                      ║
║   • Configure bootloader and system                       ║
║   • Setup users and networking                            ║
║                                                            ║
║  Commands:                                                ║
║   • ai-install    - Launch AI installer manually          ║
║   • setup-ollama  - Reinstall Ollama if needed           ║
║   • ollama list   - Show available AI models              ║
║                                                            ║
║  SSH is enabled with your authorized key.                 ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
MOTD

# Build the ISO
echo "Building ISO image..."
mkarchiso -v -w /tmp/work -o /output /build/profile
BUILDSCRIPT

chmod +x build.sh

# Build Docker image
echo "Building Docker archiso environment..."
docker build -t archiso-ai-builder .

# Run the build
echo "Building Arch AI Installer ISO..."
docker run --rm --privileged \
    -v "$BUILD_DIR:/output" \
    archiso-ai-builder \
    /output/build.sh "$SSH_KEY"

# Find the generated ISO
ISO=$(find "$BUILD_DIR" -name "*.iso" -type f | head -n1)
if [[ -z "$ISO" ]]; then
    echo "Error: No ISO file was generated!"
    exit 1
fi

ISO_SIZE=$(du -h "$ISO" | cut -f1)
echo "ISO created successfully: $ISO ($ISO_SIZE)"

# Copy ISO to current directory for easy access
FINAL_ISO="arch-ai-installer-$(date +%Y%m%d).iso"
cp "$ISO" "$(pwd)/$FINAL_ISO"
echo "ISO copied to: $(pwd)/$FINAL_ISO"

# Write to drive if requested
if [[ "$SKIP_WRITE" != "true" ]]; then
    echo ""
    echo "Writing ISO to $DESTINATION_DRIVE..."
    dd if="$ISO" of="$DESTINATION_DRIVE" bs=4M status=progress oflag=direct conv=fsync
    sync
    echo "ISO written successfully to $DESTINATION_DRIVE"
fi

# Cleanup
rm -rf "$BUILD_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "                    BUILD COMPLETE!"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "ISO Location: $(pwd)/$FINAL_ISO"
echo ""
if [[ "$SKIP_WRITE" != "true" ]]; then
    echo "The ISO has been written to: $DESTINATION_DRIVE"
    echo ""
fi
echo "To boot:"
echo "  1. Boot from the ISO/USB drive"
echo "  2. System will auto-login as root"
echo "  3. AI assistant will automatically start"
echo "  4. Follow the AI's guidance to install Arch Linux"
echo ""
echo "Manual commands available:"
echo "  • ai-install - Start AI installer"
echo "  • ollama list - Check available models"
echo ""
echo "═══════════════════════════════════════════════════════════════"