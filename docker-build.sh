#!/bin/bash
# docker-build.sh - Build AI Installer ISO using Docker (no sudo needed if in docker group)

set -euo pipefail

SSH_KEY="${1:-$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "")}"

if [[ -z "$SSH_KEY" ]]; then
    echo "Warning: No SSH key found. Continuing without SSH access..."
    SSH_KEY="# No SSH key provided"
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

# Ollama installer
mkdir -p airootfs/usr/local/bin
cat > airootfs/usr/local/bin/setup-ollama << 'OLLAMA'
#!/bin/bash
echo "Installing Ollama..."
curl -fsSL https://ollama.ai/install.sh | sh

# Create service
cat > /etc/systemd/system/ollama.service << 'SVC'
[Unit]
Description=Ollama
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/ollama serve
Restart=always
Environment="OLLAMA_HOST=0.0.0.0"

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now ollama

# Wait and pull model
sleep 5
ollama pull qwen2.5:7b || ollama pull qwen2.5:latest
echo "Ollama ready!"
OLLAMA
chmod +x airootfs/usr/local/bin/setup-ollama

# Fast-agent installer
cat > airootfs/usr/local/bin/setup-fastagent << 'FASTAGENT'
#!/bin/bash
echo "Installing Fast-Agent..."
pip install --break-system-packages fast-agent-mcp mcp
npm install -g @modelcontextprotocol/server-filesystem @modelcontextprotocol/server-fetch

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

# AI installer
cat > airootfs/root/ai-installer.py << 'AIINSTALLER'
#!/usr/bin/env python3
import os
import sys
import subprocess

def setup_environment():
    """Setup Ollama and Fast-Agent if not already installed"""
    print("\n" + "="*60)
    print("    ARCH LINUX AI-POWERED INSTALLER")
    print("="*60)

    # Check if already setup
    if not os.path.exists('/root/.setup-done'):
        print("\nFirst-time setup - Installing AI components...")
        print("This will take a few minutes...\n")

        # Setup Ollama
        print("Installing Ollama...")
        result = subprocess.run(['/usr/local/bin/setup-ollama'], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Warning: Ollama setup had issues: {result.stderr}")

        # Setup Fast-Agent
        print("\nInstalling Fast-Agent...")
        result = subprocess.run(['/usr/local/bin/setup-fastagent'], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error setting up Fast-Agent: {result.stderr}")
            return False

        # Mark as complete
        open('/root/.setup-done', 'w').close()
        print("\nSetup complete!")

    return True

# Setup environment first
if not setup_environment():
    print("\nSetup failed. You can manually run:")
    print("  /usr/local/bin/setup-ollama")
    print("  /usr/local/bin/setup-fastagent")
    print("  python /root/ai-installer.py")
    sys.exit(1)

# Now import and run
try:
    import asyncio
    from mcp_agent.core.fastagent import FastAgent
except ImportError as e:
    print(f"\nError: Could not import Fast-Agent: {e}")
    print("Please run: pip install --break-system-packages fast-agent-mcp")
    sys.exit(1)

fast = FastAgent("Arch Installer")

@fast.agent(
    instruction="""You are an Arch Linux installation expert with full system access.
    Help users partition disks, install base system, configure bootloader and system.
    Always explain actions and ask confirmation for destructive operations.""",
    servers=["filesystem", "fetch"]
)
async def main():
    print("\n" + "="*60)
    print("    ARCH LINUX AI INSTALLER")
    print("="*60)
    print("\nI'll help you install Arch Linux.")
    print("Tell me your target disk and preferences.\n")

    async with fast.run(model="generic.qwen2.5:7b") as agent:
        await agent.interactive()

if __name__ == "__main__":
    asyncio.run(main())
AIINSTALLER
chmod +x airootfs/root/ai-installer.py

# First boot setup
cat > airootfs/root/first-boot.sh << 'FIRSTBOOT'
#!/bin/bash
if [ ! -f ~/.setup-done ]; then
    echo "First boot - setting up AI installer..."
    /usr/local/bin/setup-ollama
    /usr/local/bin/setup-fastagent
    touch ~/.setup-done
    exec python /root/ai-installer.py
fi
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
    archiso-ai-builder \
    /output/build.sh "$SSH_KEY"

# Find ISO
ISO=$(find "$BUILD_DIR" -name "*.iso" -type f | head -n1)
if [[ -z "$ISO" ]]; then
    echo "Error: No ISO generated!"
    exit 1
fi

# Copy to current directory
FINAL_ISO="arch-ai-installer-$(date +%Y%m%d-%H%M%S).iso"
cp "$ISO" "$(pwd)/$FINAL_ISO"

# Cleanup
rm -rf "$BUILD_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "                   BUILD COMPLETE!"
echo "═══════════════════════════════════════════════════════════"
echo "ISO created: $(pwd)/$FINAL_ISO"
echo "Size: $(du -h "$FINAL_ISO" | cut -f1)"
echo ""
echo "Test with: ./test-iso-qemu.sh $FINAL_ISO"
echo "═══════════════════════════════════════════════════════════"