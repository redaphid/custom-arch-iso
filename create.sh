#!/bin/bash
# build-arch-rescue-docker.sh - Build custom Arch ISO using Docker

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

# Add packages
cat >> packages.x86_64 << 'PACKAGES'

# ZFS
zfs-dkms
zfs-utils
zfsbootmenu

# Tools
zellij
neovim
nodejs
npm
git
PACKAGES

# Configure SSH
mkdir -p airootfs/root/.ssh
echo "$SSH_KEY" > airootfs/root/.ssh/authorized_keys

# Enable SSH service
mkdir -p airootfs/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/sshd.service airootfs/etc/systemd/system/multi-user.target.wants/

# Add ZFS repo
echo -e '\n[archzfs]\nServer = https://archzfs.com/$repo/$arch\nSigLevel = Optional TrustAll' >> pacman.conf

# Build ISO
mkarchiso -v -w /tmp/work -o /output /build/profile
BUILDSCRIPT

chmod +x build.sh

# Build and run
docker build -t archiso-builder .
docker run --rm --privileged \
	    -v "$BUILD_DIR:/output" \
	        archiso-builder \
		    /output/build.sh "$SSH_KEY"

# Write to drive
ISO=$(find . -name "*.iso" | head -n1)
dd if="$ISO" of="$DESTINATION_DRIVE" bs=4M status=progress oflag=direct

rm -rf "$BUILD_DIR"
echo "Done!"
