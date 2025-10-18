#!/bin/bash
# Optimized build with persistent package cache
# This version mounts a persistent pacman cache to avoid re-downloading packages

set -e

echo "═══════════════════════════════════════════════════════════"
echo "  Optimized Arch Linux ISO Builder with Package Caching"
echo "═══════════════════════════════════════════════════════════"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/tmp"
PACMAN_CACHE="$SCRIPT_DIR/.pacman-cache"

# Create persistent package cache directory
mkdir -p "$PACMAN_CACHE"

if [[ ! -d "$CACHE_DIR" ]]; then
    echo "Error: Cache directory not found. Run ./download-model.sh first!"
    exit 1
fi

echo ""
echo "Using cached dependencies from: $CACHE_DIR"
echo "Using pacman cache from: $PACMAN_CACHE"

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

# Build Docker image (cached)
echo "Building Docker image..."
docker build -t archiso-ai-builder .

# Create build script
cat > build.sh << 'BUILDSCRIPT'
#!/bin/bash
set -e

echo "Setting up archiso profile..."
cp -r /usr/share/archiso/configs/releng /build/profile

# Modify packages
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

# Copy cached files
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

# ==== PARTITION RESIZE TOOLS ====
cat > /build/profile/airootfs/usr/local/bin/resize-linux-for-windows << 'RESIZESCRIPT'
#!/bin/bash
set -e

echo "═══════════════════════════════════════════════════════════"
echo "    PARTITION RESIZE SCRIPT FOR WINDOWS DUAL BOOT"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "This script will:"
echo "  1. Shrink /dev/nvme1n1p3 (Linux) from 1991GB to 1500GB"
echo "  2. Create /dev/nvme1n1p5 (Windows) with 300GB"
echo ""
echo "⚠️  WARNING: This operation cannot be undone!"
echo "⚠️  Make sure you have backups of important data!"
echo ""
read -p "Do you want to proceed? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Operation cancelled."
    exit 1
fi

echo ""
echo "Step 1: Checking filesystem..."
e2fsck -f /dev/nvme1n1p3

echo ""
echo "Step 2: Shrinking ext4 filesystem to 1500GB..."
resize2fs /dev/nvme1n1p3 1500G

echo ""
echo "Step 3: Shrinking partition to 1500GB..."
parted /dev/nvme1n1 ---pretend-input-tty <<PARTED
resizepart 3
1505GB
yes
quit
PARTED

echo ""
echo "Step 4: Creating Windows partition (300GB)..."
parted /dev/nvme1n1 mkpart primary ntfs 1505GB 1805GB

echo ""
echo "Step 5: Setting Windows partition type..."
parted /dev/nvme1n1 set 5 msftdata on

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "                  ✓ RESIZE COMPLETE!"
echo "═══════════════════════════════════════════════════════════"
echo ""
parted /dev/nvme1n1 print
echo ""
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT
RESIZESCRIPT
chmod +x /build/profile/airootfs/usr/local/bin/resize-linux-for-windows
ln -sf /usr/local/bin/resize-linux-for-windows /build/profile/airootfs/usr/bin/resize-for-windows

# Create MOTD
cat > /build/profile/airootfs/etc/motd << 'MOTD'

╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║       ARCH LINUX LIVE USB - PARTITION RESIZE EDITION             ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

📋 TASK: Resize /dev/nvme1n1p3 from 1991GB → 1500GB for Windows

═══════════════════════════════════════════════════════════════════

🔧 COMMANDS AVAILABLE:

  resize-for-windows    - Run the automated partition resize script
  lsblk                 - View current disk layout
  parted /dev/nvme1n1   - Manual partition management

═══════════════════════════════════════════════════════════════════

🚀 Quick start: Type 'resize-for-windows' and press Enter

MOTD

# Skip the problematic customize_airootfs.sh - not needed for partition tools
# Just set root password directly via passwd config
echo "root:root" > /build/profile/airootfs/etc/passwd.plaintext

# Build the ISO
echo "Building ISO with mkarchiso..."
mkarchiso -v -w /tmp/work -o /output /build/profile

echo "Build complete!"
BUILDSCRIPT
chmod +x build.sh

# Run build with persistent package cache
echo "Building ISO with persistent package cache..."
docker run --rm --privileged \
    -v "$BUILD_DIR:/build" \
    -v "$CACHE_DIR:/cache:ro" \
    -v "$PACMAN_CACHE:/var/cache/pacman/pkg" \
    -v "$BUILD_DIR:/output" \
    archiso-ai-builder \
    /build/build.sh

# Find ISO
ISO=$(find "$BUILD_DIR" -name "*.iso" -type f | head -n1)
if [[ -z "$ISO" ]]; then
    echo "Error: No ISO generated!"
    exit 1
fi

# Copy to output
OUTPUT_DIR="$SCRIPT_DIR/isos"
mkdir -p "$OUTPUT_DIR"
ISO_DATE=$(date +%Y%m%d-%H%M%S)
FINAL_ISO="arch-partition-resize-${ISO_DATE}.iso"
FINAL_PATH="$OUTPUT_DIR/$FINAL_ISO"

echo "Copying ISO to: $FINAL_PATH"
cp "$ISO" "$FINAL_PATH"

# Clean up
echo "Cleaning up..."
cd "$SCRIPT_DIR"
rm -rf "$BUILD_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "                   BUILD COMPLETE!"
echo "═══════════════════════════════════════════════════════════"
echo "ISO created: $FINAL_PATH"
echo "Size: $(du -h "$FINAL_PATH" 2>/dev/null | cut -f1)"
echo ""
echo "Package cache saved to: $PACMAN_CACHE"
echo "Next build will be much faster!"
echo ""
echo "Test with: ./test-iso.sh $FINAL_PATH"
echo "═══════════════════════════════════════════════════════════"
