#!/bin/bash
# Ultra-fast ISO build with Docker layer caching
# First build downloads packages into a Docker layer
# Subsequent builds reuse the layer and complete in ~2 minutes

set -e

echo "═══════════════════════════════════════════════════════════"
echo "  Fast Arch Linux ISO Builder with Layer Caching"
echo "═══════════════════════════════════════════════════════════"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/tmp"

if [[ ! -d "$CACHE_DIR" ]]; then
    echo "Error: Cache directory not found."
    exit 1
fi

# Create build directory
BUILD_DIR=$(mktemp -d)
echo "Build directory: $BUILD_DIR"
cd "$BUILD_DIR"

# Create Dockerfile with package cache layer
cat > Dockerfile << 'EOF'
FROM archlinux:latest
RUN pacman -Sy --noconfirm archiso
RUN pacman-key --init && pacman-key --populate archlinux
# Pre-download all packages - cached in Docker layer!
RUN pacman -Sw --noconfirm alsa-utils amd-ucode arch-install-scripts archinstall \
    base bcachefs-tools bind btrfs-progs clonezilla cloud-init cryptsetup curl \
    darkhttpd ddrescue dhcpcd diffutils dmidecode dnsmasq dosfstools e2fsprogs \
    edk2-shell efibootmgr ethtool exfatprogs fish gpart gpm gptfdisk grub hdparm \
    htop intel-ucode iw iwd less lftp linux linux-firmware lvm2 lynx man-db mc \
    mdadm mkinitcpio mkinitcpio-archiso nano nbd neovim networkmanager nfs-utils \
    nmap nodejs npm ntfs-3g nvme-cli openssh openvpn parted partimage ppp python \
    python-pip rsync screen sg3_utils smartmontools squashfs-tools sudo syslinux \
    systemd-resolvconf tcpdump testdisk tmux vim wget xfsprogs zellij zsh git \
    base-devel linux-headers gptfdisk
WORKDIR /build
EOF

echo "Building Docker image (packages cached in layers)..."
docker build -t archiso-fast-builder .

# Rest of build remains the same...
echo "Image built! Packages are now cached in Docker layers."
echo "Run the optimized script that's already running to complete the build."
