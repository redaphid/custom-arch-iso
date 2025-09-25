#!/bin/bash
# Fast ISO builder using Docker layers and caching
# This reuses as much as possible to speed up builds

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/tmp"
WORK_CACHE="$SCRIPT_DIR/.work-cache"

echo "═══════════════════════════════════════════════════════════"
echo "     Fast Arch Linux AI Installer ISO Builder"
echo "═══════════════════════════════════════════════════════════"

# Create persistent work directory
mkdir -p "$WORK_CACHE"

# Step 1: Build base Docker image if it doesn't exist
if ! docker images | grep -q "archiso-ai-base"; then
    echo "Building base Docker image (one-time)..."
    cat > /tmp/Dockerfile.base << 'EOF'
FROM archlinux:latest
RUN pacman -Sy --noconfirm archiso python python-pip nodejs npm git base-devel
RUN pacman-key --init && pacman-key --populate archlinux
# Pre-install fast-agent-mcp in the Docker image
RUN pip install --break-system-packages fast-agent-mcp mcp
WORKDIR /build
EOF
    docker build -t archiso-ai-base -f /tmp/Dockerfile.base .
else
    echo "Using existing base Docker image"
fi

# Step 2: Create fast build script
cat > /tmp/fast-build.sh << 'FASTBUILD'
#!/bin/bash
set -e

# Check if we have a cached profile
if [ -d /work-cache/profile ]; then
    echo "Using cached profile..."
    cp -r /work-cache/profile /build/
else
    echo "Creating new profile..."
    cp -r /usr/share/archiso/configs/releng /build/profile

    # Add our packages
    cat >> /build/profile/packages.x86_64 << 'PACKAGES'
python
python-pip
nodejs
npm
networkmanager
openssh
tmux
neovim
fish
git
base-devel
PACKAGES
fi

# Quick setup of our customizations
echo "Setting up customizations..."

mkdir -p /build/profile/airootfs/{usr/local/bin,var/lib/ollama,root/.config/fast-agent,etc/systemd/system,usr/bin}

# Ollama binary (symlink to mounted cache)
if [ -f /cache/ollama-binary/ollama ]; then
    cp /cache/ollama-binary/ollama /build/profile/airootfs/usr/local/bin/
    chmod +x /build/profile/airootfs/usr/local/bin/ollama
fi

# Create ai-installer wrapper
cat > /build/profile/airootfs/usr/bin/ai-installer << 'AI'
#!/bin/bash
exec fast-agent go
AI
chmod +x /build/profile/airootfs/usr/bin/ai-installer

# Fast-agent config
cat > /build/profile/airootfs/root/.config/fast-agent/fastagent.config.yaml << 'CONFIG'
default_model: "ollama:qwen2.5:7b"
logger:
  level: "info"
mcp:
  servers:
    filesystem:
      transport: "stdio"
      command: "npx"
      args: ["@modelcontextprotocol/server-filesystem", "/"]
CONFIG

# Ollama service
cat > /build/profile/airootfs/etc/systemd/system/ollama.service << 'SVC'
[Unit]
Description=Ollama
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ollama serve
Environment="OLLAMA_MODELS=/var/lib/ollama/models"
Restart=always

[Install]
WantedBy=multi-user.target
SVC

# Auto-start fast-agent
mkdir -p /build/profile/airootfs/etc/systemd/system/getty@tty1.service.d
cat > /build/profile/airootfs/etc/systemd/system/getty@tty1.service.d/override.conf << 'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin root - $TERM
Type=idle
StandardInput=tty
StandardOutput=tty
GETTY

cat > /build/profile/airootfs/root/.bash_profile << 'PROFILE'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    # Start services
    systemctl start ollama 2>/dev/null
    sleep 2
    # Launch fast-agent
    exec fast-agent go
fi
PROFILE

# Enable SSH
ln -sf /usr/lib/systemd/system/sshd.service /build/profile/airootfs/etc/systemd/system/multi-user.target.wants/
echo 'root:root' > /build/profile/airootfs/root/.credentials
echo 'PermitRootLogin yes' >> /build/profile/airootfs/etc/ssh/sshd_config

# Install Python packages in the airootfs
cat > /build/profile/airootfs/root/customize_airootfs.sh << 'CUSTOM'
#!/bin/bash
set -e
# Set root password
echo 'root:root' | chpasswd
# Install fast-agent if not already installed
pip install --break-system-packages fast-agent-mcp mcp 2>/dev/null || true
# Clean up
rm -rf /var/cache/pacman/pkg/*
rm -rf /root/.cache
CUSTOM
chmod +x /build/profile/airootfs/root/customize_airootfs.sh

# Copy models efficiently (hard link if possible)
if [ -d /cache/models ]; then
    echo "Installing models..."
    mkdir -p /build/profile/airootfs/var/lib/ollama
    cp -al /cache/models/* /build/profile/airootfs/var/lib/ollama/ 2>/dev/null || \
    cp -r /cache/models/* /build/profile/airootfs/var/lib/ollama/
fi

# Save profile for next time
cp -r /build/profile /work-cache/ 2>/dev/null || true

# Build ISO with existing work directory if available
echo "Building ISO..."
if [ -d /work-cache/work ]; then
    echo "Using cached work directory..."
    mkarchiso -v -w /work-cache/work -o /output /build/profile
else
    mkarchiso -v -w /tmp/work -o /output /build/profile
    # Save work directory for next time
    cp -r /tmp/work /work-cache/ 2>/dev/null || true
fi

echo "Build complete!"
FASTBUILD
chmod +x /tmp/fast-build.sh

# Step 3: Run fast build
BUILD_DIR=$(mktemp -d)
echo "Output directory: $BUILD_DIR"

echo "Running fast build..."
docker run --rm --privileged \
    -v "$CACHE_DIR:/cache:ro" \
    -v "$WORK_CACHE:/work-cache" \
    -v "$BUILD_DIR:/output" \
    -v "/tmp/fast-build.sh:/build/fast-build.sh:ro" \
    archiso-ai-base \
    /build/fast-build.sh

# Find and move ISO
ISO=$(find "$BUILD_DIR" -name "*.iso" -type f | head -n1)
if [ -n "$ISO" ]; then
    ISO_DATE=$(date +%Y%m%d-%H%M%S)
    FINAL_ISO="$SCRIPT_DIR/isos/arch-ai-installer-${ISO_DATE}.iso"
    mkdir -p "$SCRIPT_DIR/isos"
    mv "$ISO" "$FINAL_ISO"
    rm -rf "$BUILD_DIR"

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "ISO created: $FINAL_ISO"
    echo "Size: $(du -h "$FINAL_ISO" | cut -f1)"
    echo "═══════════════════════════════════════════════════════════"
else
    echo "Error: No ISO found!"
    exit 1
fi