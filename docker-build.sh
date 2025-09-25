#!/bin/bash
# docker-build.sh - Build AI Installer ISO using Docker (no sudo needed if in docker group)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="${1:-$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "")}"
CACHE_DIR="$SCRIPT_DIR/tmp"

if [[ -z "$SSH_KEY" ]]; then
    echo "Warning: No SSH key found. Continuing without SSH access..."
    SSH_KEY="# No SSH key provided"
fi

# Check if cache exists
if [[ ! -d "$CACHE_DIR" ]] || [[ ! -d "$CACHE_DIR/models" ]]; then
    echo "Error: Cache directory not found at $CACHE_DIR"
    echo "Please run ./download-model.sh first to download dependencies"
    exit 1
fi

# Check Docker access
if ! docker info &>/dev/null 2>&1; then
    echo "Cannot access Docker. Either:"
    echo "  1. Add yourself to docker group: sudo usermod -aG docker $USER"
    echo "     Then logout and login again"
    echo "  2. Or run this script with sudo"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════"
echo "     Building Arch Linux AI Installer ISO with Docker"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Using cached dependencies from: $CACHE_DIR"
echo ""

# Save the original script directory before changing directories
ORIGINAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create build directory
BUILD_DIR=$(mktemp -d)
echo "Build directory: $BUILD_DIR"
cd "$BUILD_DIR"

# Create Dockerfile
cat > Dockerfile << 'EOF'
FROM archlinux:latest
RUN pacman -Sy --noconfirm archiso
RUN pacman-key --init && pacman-key --populate archlinux
WORKDIR /build
EOF

# Create the build script
cat > build.sh << 'BUILDSCRIPT'
#!/bin/bash
set -euo pipefail

SSH_KEY="$1"

# Copy releng profile
cp -r /usr/share/archiso/configs/releng /build/profile
cd /build/profile

# Add packages
cat >> packages.x86_64 << 'PACKAGES'

# Core tools
zellij
tmux
neovim
git
base-devel
linux-headers
fish

# Python and Node
python
python-pip
nodejs
npm

# Network
networkmanager
openssh
wget
curl

# System
htop
parted
gptfdisk
PACKAGES

# SSH setup
if [[ "$SSH_KEY" != "# No SSH key provided" ]]; then
    mkdir -p airootfs/root/.ssh
    echo "$SSH_KEY" > airootfs/root/.ssh/authorized_keys
    chmod 700 airootfs/root/.ssh
    chmod 600 airootfs/root/.ssh/authorized_keys
fi

# Enable services
mkdir -p airootfs/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/sshd.service airootfs/etc/systemd/system/multi-user.target.wants/
ln -sf /usr/lib/systemd/system/NetworkManager.service airootfs/etc/systemd/system/multi-user.target.wants/

# Copy cached Ollama binary and models
echo "Copying cached Ollama binary..."
mkdir -p airootfs/usr/local/bin
if [[ -f /cache/ollama-binary/ollama ]]; then
    cp /cache/ollama-binary/ollama airootfs/usr/local/bin/
    chmod +x airootfs/usr/local/bin/ollama
else
    echo "Warning: Cached Ollama binary not found"
fi

# Copy cached models
echo "Copying cached models..."
mkdir -p airootfs/root/.ollama
if [[ -d /cache/models ]]; then
    cp -r /cache/models/* airootfs/root/.ollama/ 2>/dev/null || true
fi

# Copy Python packages
echo "Copying Python package cache..."
mkdir -p airootfs/root/.pip-cache
if [[ -d /cache/pip-cache ]]; then
    cp -r /cache/pip-cache/* airootfs/root/.pip-cache/ 2>/dev/null || true
fi

# Copy NPM packages
echo "Copying NPM package cache..."
mkdir -p airootfs/root/.npm-cache
if [[ -d /cache/npm-cache ]]; then
    cp -r /cache/npm-cache/* airootfs/root/.npm-cache/ 2>/dev/null || true
fi

# Create Ollama service directly in the image
cat > airootfs/etc/systemd/system/ollama.service << 'OLLAMA'
[Unit]
Description=Ollama
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_MODELS=/root/.ollama/models"
User=root

[Install]
WantedBy=multi-user.target
OLLAMA

# Enable the service
ln -sf /etc/systemd/system/ollama.service airootfs/etc/systemd/system/multi-user.target.wants/

# Install Python packages during build
cat > airootfs/usr/local/bin/install-python-deps << 'PYDEPS'
#!/bin/bash
echo "Installing Python dependencies..."

# First try cached packages
if [[ -d /root/.pip-cache ]] && ls /root/.pip-cache/*.whl &>/dev/null; then
    echo "Installing from cache..."
    pip install --break-system-packages /root/.pip-cache/*.whl 2>/dev/null
fi

# Ensure fast-agent-mcp is installed
if ! python -c "import fast_agent_mcp" 2>/dev/null; then
    echo "Installing fast-agent-mcp..."
    pip install --break-system-packages fast-agent-mcp
fi
PYDEPS
chmod +x airootfs/usr/local/bin/install-python-deps

# Run installation at boot
cat > airootfs/etc/systemd/system/install-deps.service << 'DEPSVC'
[Unit]
Description=Install Python Dependencies
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/install-python-deps
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
DEPSVC
ln -sf /etc/systemd/system/install-deps.service airootfs/etc/systemd/system/multi-user.target.wants/

# Fast-agent installer (uses cached packages)
cat > airootfs/usr/local/bin/setup-fastagent << 'FASTAGENT'
#!/bin/bash
echo "Setting up Fast-Agent configuration..."

# Install from cached NPM packages
if [[ -d /root/.npm-cache ]] && ls /root/.npm-cache/*.tgz &>/dev/null; then
    echo "Installing NPM packages from cache..."
    for pkg in /root/.npm-cache/*.tgz; do
        npm install -g "$pkg" 2>/dev/null || true
    done
else
    echo "No NPM cache found, downloading..."
    npm install -g @modelcontextprotocol/server-filesystem @modelcontextprotocol/server-fetch
fi

# Config
mkdir -p /root/.config/fast-agent
cat > /root/.config/fast-agent/fastagent.config.yaml << 'CFG'
default_model: "generic.qwen2.5:7b"
logger:
  level: "info"
  type: "console"
  progress_display: true
  show_chat: true
  show_tools: true
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
CFG
echo "Fast-Agent ready!"
FASTAGENT
chmod +x airootfs/usr/local/bin/setup-fastagent

# AI installer (simplified - everything pre-installed)
cat > airootfs/root/ai-installer.py << 'AIINSTALLER'
#!/usr/bin/env python3
"""
Arch Linux AI-Powered Installer
"""
import os
import sys
import subprocess
import time

def main():
    """Main installer function"""
    print("\n" + "="*60)
    print("    ARCH LINUX AI-POWERED INSTALLER")
    print("="*60)

    # Ensure services are running
    print("\nStarting AI services...")
    subprocess.run(['systemctl', 'start', 'ollama'], check=False)
    time.sleep(3)

    print("\n" + "="*60)
    print("    Welcome to AI-Powered Arch Linux Installer!")
    print("="*60)
    print("\nI'm your AI assistant for installing Arch Linux.")
    print("I can help you with:")
    print("  • Partitioning disks")
    print("  • Formatting filesystems")
    print("  • Installing base system")
    print("  • Configuring bootloader")
    print("  • Setting up networking")
    print("  • And much more!")
    print("\nYou can ask me anything about the installation process.")
    print("Type 'exit' or Ctrl+C to quit.\n")

    # Initialize and run the CLI
    try:
        # Try importing with the correct module name
        from fast_agent_mcp import FastAgentCLI
        cli = FastAgentCLI()
        cli.run()
    except ImportError:
        try:
            # Alternative import path
            import fast_agent_mcp.cli as cli_module
            cli = cli_module.FastAgentCLI()
            cli.run()
        except ImportError as e:
            print(f"Error: Could not import Fast-Agent: {e}")
            print("\nTrying to install dependencies...")
            subprocess.run(['pip', 'install', '--break-system-packages', 'fast-agent-mcp'])
            print("\nPlease restart the installer.")
    except KeyboardInterrupt:
        print("\n\nInstaller interrupted. You can restart by running:")
        print("  python /root/ai-installer.py")
    except Exception as e:
        print(f"\nError running AI assistant: {e}")
        print("You can try manual installation or restart the installer.")

if __name__ == "__main__":
    main()
AIINSTALLER
chmod +x airootfs/root/ai-installer.py

# First boot setup (everything is pre-installed)
cat > airootfs/root/first-boot.sh << 'FIRSTBOOT'
#!/bin/bash
# Start ollama service if not running
systemctl start ollama 2>/dev/null || /usr/local/bin/setup-ollama

# Setup fast-agent config if needed
if [ ! -f ~/.config/fast-agent/fastagent.config.yaml ]; then
    /usr/local/bin/setup-fastagent
fi

# Run the AI installer
python /root/ai-installer.py
FIRSTBOOT
chmod +x airootfs/root/first-boot.sh

# Auto-login
mkdir -p airootfs/etc/systemd/system/getty@tty1.service.d
cat > airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTO'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin root %I $TERM
AUTO

# Bash profile
cat > airootfs/root/.bash_profile << 'PROF'
# Auto-start AI installer on login
if [ -z "$AI_INSTALLER_RUNNING" ]; then
    export AI_INSTALLER_RUNNING=1
    python /root/ai-installer.py
fi
PROF

# MOTD
cat > airootfs/etc/motd << 'MOTD'
══════════════════════════════════════════════════════
         ARCH LINUX AI-POWERED INSTALLER
══════════════════════════════════════════════════════
 AI assistant will help you install Arch Linux
 Commands: ai-installer, setup-ollama, ollama list
══════════════════════════════════════════════════════
MOTD

# Build ISO
mkarchiso -v -w /tmp/work -o /output /build/profile
BUILDSCRIPT

chmod +x build.sh

# Build Docker image
echo "Building Docker image..."
docker build -t archiso-ai-builder .

# Run build in container
echo "Building ISO (this will take several minutes)..."
docker run --rm --privileged \
    -v "$BUILD_DIR:/output" \
    -v "$CACHE_DIR:/cache:ro" \
    archiso-ai-builder \
    /output/build.sh "$SSH_KEY"

# Find ISO
ISO=$(find "$BUILD_DIR" -name "*.iso" -type f | head -n1)
if [[ -z "$ISO" ]]; then
    echo "Error: No ISO generated!"
    exit 1
fi

# Create output directory
OUTPUT_DIR="$ORIGINAL_SCRIPT_DIR/isos"
mkdir -p "$OUTPUT_DIR"

# Copy to isos directory with ISO 8601 date format
# Format: arch-ai-installer-YYYYMMDD-HHMMSS.iso
ISO_DATE=$(date +%Y%m%d-%H%M%S)
FINAL_ISO="arch-ai-installer-${ISO_DATE}.iso"
FINAL_PATH="$OUTPUT_DIR/$FINAL_ISO"

echo "Copying ISO to: $FINAL_PATH"
cp "$ISO" "$FINAL_PATH"

# Verify copy succeeded
if [[ ! -f "$FINAL_PATH" ]]; then
    echo "Error: Failed to copy ISO to $FINAL_PATH"
    echo "ISO is still available at: $ISO"
    echo "Skipping cleanup to preserve ISO"
else
    # Cleanup build directory (but preserve the ISO in isos/)
    echo "Cleaning up build directory..."
    rm -rf "$BUILD_DIR"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "                   BUILD COMPLETE!"
echo "═══════════════════════════════════════════════════════════"
echo "ISO created: $FINAL_PATH"
echo "Size: $(du -h "$FINAL_PATH" 2>/dev/null | cut -f1)"
echo ""
echo "Test with: ./test-iso.sh"
echo "Or specify: ./test-iso.sh $FINAL_PATH"
echo "═══════════════════════════════════════════════════════════"