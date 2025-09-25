#!/bin/bash
# Build Arch Linux AI Installer ISO with Docker
# This creates an ISO with Ollama, Qwen model, and fast-agent pre-installed

set -e

echo "═══════════════════════════════════════════════════════════"
echo "     Building Arch Linux AI Installer ISO with Docker"
echo "═══════════════════════════════════════════════════════════"

# Check for cached dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/tmp"
if [[ ! -d "$CACHE_DIR" ]]; then
    echo "Error: Cache directory not found. Run ./download-model.sh first!"
    exit 1
fi

echo ""
echo "Using cached dependencies from: $CACHE_DIR"

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

# Build Docker image
echo "Building Docker image..."
docker build -t archiso-ai-builder .

# Create build script that runs inside container
cat > build.sh << 'BUILDSCRIPT'
#!/bin/bash
set -e

echo "Setting up archiso profile..."
cp -r /usr/share/archiso/configs/releng /build/profile

# Modify packages.x86_64 to include our requirements
cat >> /build/profile/packages.x86_64 << 'PACKAGES'
zellij
tmux
neovim
git
base-devel
linux-headers
fish
python
python-pip
nodejs
npm
networkmanager
openssh
wget
curl
htop
parted
gptfdisk
PACKAGES

# Copy cached files from host
echo "Copying cached files..."
mkdir -p /build/profile/airootfs/{usr/local/bin,var/lib/ollama,root/.config/fast-agent,etc/systemd/system,usr/bin}

# Ollama binary
if [[ -d /cache/ollama-binary ]]; then
    echo "Installing Ollama binary..."
    cp /cache/ollama-binary/ollama /build/profile/airootfs/usr/local/bin/
    chmod +x /build/profile/airootfs/usr/local/bin/ollama
fi

# Ollama models
if [[ -d /cache/models ]]; then
    echo "Installing Ollama models..."
    cp -r /cache/models/* /build/profile/airootfs/var/lib/ollama/
fi

# Create ai-installer command
cat > /build/profile/airootfs/usr/local/bin/ai-installer << 'AIINSTALLER'
#!/bin/bash
exec python /root/ai-installer.py
AIINSTALLER
chmod +x /build/profile/airootfs/usr/local/bin/ai-installer
ln -sf /usr/local/bin/ai-installer /build/profile/airootfs/usr/bin/ai-installer

# Create the Python AI installer
cat > /build/profile/airootfs/root/ai-installer.py << 'PYINSTALLER'
#!/usr/bin/env python3
import subprocess
import time
import sys
import os

def main():
    print("\n" + "="*60)
    print("    ARCH LINUX AI-POWERED INSTALLER")
    print("="*60)

    # Start Ollama if not running
    print("\nStarting Ollama service...")
    subprocess.run(['systemctl', 'start', 'ollama'], check=False)
    time.sleep(2)

    print("\nLaunching fast-agent interactive mode...")
    print("Type 'exit' to quit the AI assistant.")
    print("-" * 60)

    # Launch fast-agent in interactive mode
    try:
        subprocess.run(['fast-agent', 'go'], check=False)
    except KeyboardInterrupt:
        print("\nExiting AI installer...")
    except Exception as e:
        print(f"Error launching fast-agent: {e}")
        print("You can try running: fast-agent go")

if __name__ == "__main__":
    main()
PYINSTALLER

# Create fast-agent configuration
cat > /build/profile/airootfs/root/.config/fast-agent/fastagent.config.yaml << 'CONFIG'
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
CONFIG

# Create Ollama service
cat > /build/profile/airootfs/etc/systemd/system/ollama.service << 'OLLAMASVC'
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
Environment="OLLAMA_MODELS=/var/lib/ollama/models"
User=root

[Install]
WantedBy=multi-user.target
OLLAMASVC

# Enable services
mkdir -p /build/profile/airootfs/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/ollama.service /build/profile/airootfs/etc/systemd/system/multi-user.target.wants/
ln -sf /usr/lib/systemd/system/sshd.service /build/profile/airootfs/etc/systemd/system/multi-user.target.wants/

# Create auto-start service for AI installer
cat > /build/profile/airootfs/etc/systemd/system/ai-installer.service << 'AISVC'
[Unit]
Description=AI Installer Auto-Start
After=multi-user.target ollama.service
Wants=ollama.service

[Service]
Type=idle
ExecStart=/usr/bin/fast-agent go
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
Restart=on-failure
User=root
WorkingDirectory=/root

[Install]
WantedBy=multi-user.target
AISVC
ln -sf /etc/systemd/system/ai-installer.service /build/profile/airootfs/etc/systemd/system/multi-user.target.wants/

# Auto-login configuration
mkdir -p /build/profile/airootfs/etc/systemd/system/getty@tty1.service.d
cat > /build/profile/airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin root %I $TERM
AUTOLOGIN

# Create a script to install Python packages AFTER the system is built
cat > /build/profile/airootfs/root/.install-packages.sh << 'INSTALLPKGS'
#!/bin/bash
# This will be run by customize_airootfs.sh
echo "Installing Python packages..."
pip install --break-system-packages fast-agent-mcp mcp 2>/dev/null || {
    # Try installing from wheels if available
    if [[ -d /tmp/pip-wheels ]]; then
        cd /tmp/pip-wheels
        for wheel in *.whl; do
            [ -f "$wheel" ] && pip install --break-system-packages "$wheel" 2>/dev/null
        done
    fi
}

# Verify installation
python -c "import fast_agent_mcp" && echo "✓ fast-agent-mcp installed" || echo "⚠ fast-agent-mcp missing"

# Clean up
rm -rf /root/.cache/pip /tmp/pip-wheels
INSTALLPKGS
chmod +x /build/profile/airootfs/root/.install-packages.sh

# Create customize_airootfs.sh for mkarchiso to run
cat > /build/profile/airootfs/root/customize_airootfs.sh << 'CUSTOMIZE'
#!/bin/bash
set -e -u

echo "Customizing airootfs..."

# Run package installation
/root/.install-packages.sh

# Set root password for SSH debugging
echo 'root:root' | chpasswd
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config

# Clean up
rm -rf /var/cache/pacman/pkg/*
rm -f /root/.install-packages.sh

echo "Customization complete"
CUSTOMIZE
chmod +x /build/profile/airootfs/root/customize_airootfs.sh

# Copy pip wheels if available
if [[ -d /cache/pip-cache ]]; then
    echo "Copying pip wheels for installation..."
    mkdir -p /build/profile/airootfs/tmp/pip-wheels
    cp /cache/pip-cache/*.whl /build/profile/airootfs/tmp/pip-wheels/ 2>/dev/null || true
fi

# Build the ISO
echo "Building ISO with mkarchiso..."
mkarchiso -v -w /tmp/work -o /output /build/profile

echo "Build complete!"
BUILDSCRIPT
chmod +x build.sh

# Run build in Docker container with cache mounted
echo "Building ISO (this will take several minutes)..."
docker run --rm --privileged \
    -v "$BUILD_DIR:/build" \
    -v "$CACHE_DIR:/cache:ro" \
    -v "$BUILD_DIR:/output" \
    archiso-ai-builder \
    /build/build.sh

# Find ISO
ISO=$(find "$BUILD_DIR" -name "*.iso" -type f | head -n1)
if [[ -z "$ISO" ]]; then
    echo "Error: No ISO generated!"
    exit 1
fi

# Create output directory
OUTPUT_DIR="$ORIGINAL_SCRIPT_DIR/isos"
mkdir -p "$OUTPUT_DIR"

# Copy to output directory with timestamp
ISO_DATE=$(date +%Y%m%d-%H%M%S)
FINAL_ISO="arch-ai-installer-${ISO_DATE}.iso"
FINAL_PATH="$OUTPUT_DIR/$FINAL_ISO"

echo "Copying ISO to: $FINAL_PATH"
cp "$ISO" "$FINAL_PATH"

# Verify file exists
if [[ ! -f "$FINAL_PATH" ]]; then
    echo "Error: Failed to copy ISO to $FINAL_PATH"
    exit 1
fi

# Clean up
echo "Cleaning up build directory..."
cd "$ORIGINAL_SCRIPT_DIR"
rm -rf "$BUILD_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "                   BUILD COMPLETE!"
echo "═══════════════════════════════════════════════════════════"
echo "ISO created: $FINAL_PATH"
echo "Size: $(du -h "$FINAL_PATH" 2>/dev/null | cut -f1)"
echo ""
echo "Test with: ./test-iso.sh"
echo "Or specify: ./test-iso.sh $FINAL_PATH"
echo ""
echo "The ISO will boot directly into fast-agent AI assistant!"
echo "SSH access available: root/root (for debugging)"
echo "═══════════════════════════════════════════════════════════"