#!/bin/bash
# Fast ISO build with packages cached in Docker layers

set -e

echo "═══════════════════════════════════════════════════════════"
echo "  Fast ISO Builder with Docker Layer Package Caching"
echo "═══════════════════════════════════════════════════════════"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/tmp"

# Create build directory
BUILD_DIR=$(mktemp -d)
echo "Build directory: $BUILD_DIR"
cd "$BUILD_DIR"

# Create Dockerfile with packages cached in layers
cat > Dockerfile << 'DOCKERFILEEOF'
FROM archlinux:latest

# Install archiso
RUN pacman -Sy --noconfirm archiso

# Initialize pacman keys  
RUN pacman-key --init && pacman-key --populate archlinux

# Download all packages to Docker layer cache
# This is the KEY optimization - packages stay in the layer!
RUN pacman -Sw --noconfirm \
    alsa-utils amd-ucode arch-install-scripts archinstall b43-fwcutter base \
    bcachefs-tools bind bolt brltty broadcom-wl btrfs-progs clonezilla cloud-init \
    cryptsetup darkhttpd ddrescue dhcpcd diffutils dmidecode dmraid dnsmasq \
    dosfstools e2fsprogs edk2-shell efibootmgr espeakup ethtool exfatprogs \
    f2fs-tools fatresize foot-terminfo fsarchiver gpart gpm gptfdisk grml-zsh-config \
    grub hdparm hyperv intel-ucode irssi iw iwd jfsutils kitty-terminfo ldns less \
    lftp libfido2 libusb-compat linux linux-atm linux-firmware linux-firmware-marvell \
    livecd-sounds lsscsi lvm2 lynx man-db man-pages mc mdadm memtest86+ memtest86+-efi \
    mkinitcpio mkinitcpio-archiso mkinitcpio-nfs-utils mmc-utils modemmanager mtools \
    nano nbd ndisc6 nfs-utils nilfs-utils nmap ntfs-3g nvme-cli open-iscsi \
    open-vm-tools openconnect openpgp-card-tools openssh openvpn partclone parted \
    partimage pcsclite ppp pptpclient pv qemu-guest-agent refind reflector rsync \
    rxvt-unicode-terminfo screen sdparm sequoia-sq sg3_utils smartmontools sof-firmware \
    squashfs-tools sudo syslinux systemd-resolvconf tcpdump terminus-font testdisk \
    tmux tpm2-tools tpm2-tss udftools usb_modeswitch usbmuxd usbutils vim \
    virtualbox-guest-utils-nox vpnc wireless-regdb wireless_tools wpa_supplicant \
    wvdial xdg-utils xfsprogs xl2tpd zsh zellij neovim git base-devel \
    linux-headers fish python python-pip nodejs npm networkmanager wget curl htop

WORKDIR /build
DOCKERFILEEOF

echo ""
echo "Building Docker image with package cache..."
echo "(This downloads ~1.1GB once, then cached in layers forever)"
docker build -t archiso-layered-builder .

# Create ISO build script
cat > build.sh << 'BUILDSCRIPTEOF'
#!/bin/bash
set -e

echo "Setting up archiso profile..."
cp -r /usr/share/archiso/configs/releng /build/profile

# Add custom packages
cat >> /build/profile/packages.x86_64 << 'PKGS'
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
PKGS

# Setup directories
mkdir -p /build/profile/airootfs/{usr/local/bin,var/lib/ollama,usr/bin}

# Copy Ollama if available
if [[ -d /cache/ollama-binary ]]; then
    cp /cache/ollama-binary/ollama /build/profile/airootfs/usr/local/bin/
    chmod +x /build/profile/airootfs/usr/local/bin/ollama
fi

if [[ -d /cache/models ]]; then
    cp -r /cache/models/* /build/profile/airootfs/var/lib/ollama/
fi

# Create partition resize script
cat > /build/profile/airootfs/usr/local/bin/resize-linux-for-windows << 'RESIZE'
#!/bin/bash
set -e

echo "═══════════════════════════════════════════════════════════"
echo "    PARTITION RESIZE SCRIPT FOR WINDOWS DUAL BOOT"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "This will:"
echo "  1. Shrink /dev/nvme1n1p3 (Linux) from 1991GB to 1500GB"
echo "  2. Create /dev/nvme1n1p5 (Windows) with 300GB"
echo ""
echo "⚠️  WARNING: Cannot be undone! Backup your data!"
echo ""
read -p "Proceed? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Cancelled."
    exit 1
fi

echo "Step 1: Checking filesystem..."
e2fsck -f /dev/nvme1n1p3

echo "Step 2: Shrinking filesystem to 1500GB..."
resize2fs /dev/nvme1n1p3 1500G

echo "Step 3: Shrinking partition..."
parted /dev/nvme1n1 ---pretend-input-tty <<PARTED
resizepart 3
1505GB
yes
quit
PARTED

echo "Step 4: Creating Windows partition..."
parted /dev/nvme1n1 mkpart primary ntfs 1505GB 1805GB

echo "Step 5: Setting partition type..."
parted /dev/nvme1n1 set 5 msftdata on

echo ""
echo "✓ RESIZE COMPLETE!"
echo ""
parted /dev/nvme1n1 print
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT
RESIZE
chmod +x /build/profile/airootfs/usr/local/bin/resize-linux-for-windows
ln -sf /usr/local/bin/resize-linux-for-windows /build/profile/airootfs/usr/bin/resize-for-windows

# Create MOTD
cat > /build/profile/airootfs/etc/motd << 'MOTD'

╔══════════════════════════════════════════════════════════════════╗
║       ARCH LINUX LIVE USB - PARTITION RESIZE EDITION             ║
╚══════════════════════════════════════════════════════════════════╝

📋 TASK: Resize /dev/nvme1n1p3 from 1991GB → 1500GB for Windows

🔧 QUICK START: resize-for-windows

MOTD

# Build ISO (uses packages from Docker layer cache!)
echo "Building ISO with mkarchiso..."
mkarchiso -v -w /tmp/work -o /output /build/profile
BUILDSCRIPTEOF
chmod +x build.sh

# Run build
echo ""
echo "Building ISO (packages cached in Docker layers)..."
docker run --rm --privileged \
    -v "$BUILD_DIR:/build" \
    -v "$CACHE_DIR:/cache:ro" \
    -v "$BUILD_DIR:/output" \
    archiso-layered-builder \
    /build/build.sh

# Find ISO
ISO=$(find "$BUILD_DIR" -name "*.iso" -type f | head -n1)
if [[ -z "$ISO" ]]; then
    echo "Error: No ISO found!"
    exit 1
fi

# Copy to output
OUTPUT_DIR="$SCRIPT_DIR/isos"
mkdir -p "$OUTPUT_DIR"
ISO_DATE=$(date +%Y%m%d-%H%M%S)
FINAL_ISO="arch-partition-resize-${ISO_DATE}.iso"
FINAL_PATH="$OUTPUT_DIR/$FINAL_ISO"

cp "$ISO" "$FINAL_PATH"

# Cleanup
cd "$SCRIPT_DIR"
rm -rf "$BUILD_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "                   BUILD COMPLETE!"
echo "═══════════════════════════════════════════════════════════"
echo "ISO: $FINAL_PATH"
echo "Size: $(du -h "$FINAL_PATH" | cut -f1)"
echo ""
echo "Docker image 'archiso-layered-builder' now has packages cached"
echo "Next build will be MUCH faster!"
echo ""
echo "Test: ./test-iso.sh $FINAL_PATH"
echo "═══════════════════════════════════════════════════════════"
