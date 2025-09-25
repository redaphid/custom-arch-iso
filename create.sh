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

# Add our packages (no ZFS for now)
cat >> packages.x86_64 << 'PACKAGES'

# Tools
zellij
neovim
nodejs
npm
git
wget
base-devel
linux-headers
PACKAGES

# Configure SSH
mkdir -p airootfs/root/.ssh
echo "$SSH_KEY" > airootfs/root/.ssh/authorized_keys

# Enable SSH service
mkdir -p airootfs/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/sshd.service airootfs/etc/systemd/system/multi-user.target.wants/

# Create ZFS installer script
cat > airootfs/root/install-zfs.sh << 'ZFSINSTALL'
#!/bin/bash
# Install ZFS on the live system

echo "Installing ZFS support..."

# Add archzfs repository
if ! grep -q archzfs /etc/pacman.conf; then
    echo -e '\n[archzfs]\nServer = https://archzfs.com/$repo/$arch' >> /etc/pacman.conf
fi

# Initialize keyring if needed
if ! pacman-key --list-keys > /dev/null 2>&1; then
    pacman-key --init
    pacman-key --populate archlinux
fi

# Import and trust the archzfs key
pacman-key --recv-keys DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76

# Update and install
pacman -Sy
pacman -S --noconfirm zfs-dkms zfs-utils

# Load ZFS module
modprobe zfs

echo "ZFS installed and loaded!"
echo ""
echo "For zfsbootmenu (from AUR):"
echo "  git clone https://aur.archlinux.org/zfsbootmenu.git"
echo "  cd zfsbootmenu && makepkg -si"
ZFSINSTALL
chmod +x airootfs/root/install-zfs.sh

# Create 1Password installer using AUR
cat > airootfs/usr/local/bin/install-1password << 'OPINSTALL'
#!/bin/bash
echo "Installing 1Password CLI from AUR..."

# Create temporary build directory
BUILD_DIR=$(mktemp -d)
cd "$BUILD_DIR"

# Clone AUR package
git clone https://aur.archlinux.org/1password-cli.git
cd 1password-cli

# Build and install
makepkg -si --noconfirm

# Cleanup
cd /
rm -rf "$BUILD_DIR"

echo "1Password CLI installed. Run 'op signin' to authenticate."
OPINSTALL
chmod +x airootfs/usr/local/bin/install-1password

# Create Claude Code helper
cat > airootfs/root/claude-setup.sh << 'CLAUDESETUP'
#!/bin/bash
echo "Claude Code Setup:"
echo ""
echo "1. Set your API key:"
echo "   export ANTHROPIC_API_KEY='your-key-here'"
echo ""
echo "2. Run Claude Code:"
echo "   npx @anthropic-ai/claude-code"
echo ""
echo "Or with 1Password:"
echo "   export ANTHROPIC_API_KEY=$(op item get 'Anthropic' --field credential)"
CLAUDESETUP
chmod +x airootfs/root/claude-setup.sh

# Create welcome message
cat > airootfs/etc/motd << 'MOTD'
==============================================
    Arch Linux ZFS Rescue System
==============================================
Network should be auto-configured via DHCP.
SSH is enabled with your key.

Quick setup:
1. /root/install-zfs.sh      # Install ZFS support
2. install-1password          # Install 1Password CLI (from AUR)
3. /root/claude-setup.sh      # Claude Code instructions

Terminal: zellij
Editor: nvim
==============================================
MOTD

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
echo "Success! Boot from $DESTINATION_DRIVE and run:"
echo "  /root/install-zfs.sh"
echo "  install-1password"
