#!/bin/bash
# Quick ISO patcher - modifies existing ISO without full rebuild
# This is the FASTEST way to test changes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/tmp"

# Find latest ISO
LATEST_ISO=$(ls -t "$SCRIPT_DIR/isos"/*.iso 2>/dev/null | head -n1)
if [ -z "$LATEST_ISO" ] || [ ! -f "$LATEST_ISO" ]; then
    echo "No ISO found to patch. Run docker-build-fast.sh first"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════"
echo "     Quick ISO Patcher"
echo "═══════════════════════════════════════════════════════════"
echo "Patching: $(basename $LATEST_ISO)"
echo ""

WORK_DIR=$(mktemp -d)
echo "Work directory: $WORK_DIR"

# Extract the ISO
echo "Extracting ISO..."
cd "$WORK_DIR"
7z x "$LATEST_ISO" > /dev/null 2>&1 || xorriso -osirrox on -indev "$LATEST_ISO" -extract / .

# Find and extract the squashfs
SQUASHFS=$(find . -name "airootfs.sfs" -o -name "*.squashfs" | head -n1)
if [ -z "$SQUASHFS" ]; then
    echo "Error: Could not find squashfs in ISO"
    exit 1
fi

echo "Extracting squashfs..."
unsquashfs -d squashfs-root "$SQUASHFS"

# Apply our patches
echo "Applying patches..."

# Update ai-installer to directly launch fast-agent
cat > squashfs-root/usr/bin/ai-installer << 'AILAUNCH'
#!/bin/bash
# Direct launcher for fast-agent
systemctl start ollama 2>/dev/null || /usr/local/bin/ollama serve &
sleep 2
exec fast-agent go
AILAUNCH
chmod +x squashfs-root/usr/bin/ai-installer

# Update bash profile to auto-launch
cat > squashfs-root/root/.bash_profile << 'PROFILE'
# Auto-launch fast-agent on first tty
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    clear
    echo "Starting AI Assistant..."
    systemctl start ollama 2>/dev/null || /usr/local/bin/ollama serve &
    sleep 3
    exec fast-agent go
fi
PROFILE

# Ensure fast-agent is installed
echo "Ensuring fast-agent is installed..."
cat > squashfs-root/tmp/install-fastagent.sh << 'INSTALL'
#!/bin/bash
pip install --break-system-packages --root=/squashfs-root --prefix=/usr fast-agent-mcp mcp 2>/dev/null
INSTALL
chmod +x squashfs-root/tmp/install-fastagent.sh

# Run in chroot to install packages
arch-chroot squashfs-root /tmp/install-fastagent.sh 2>/dev/null || {
    echo "Direct install failed, trying alternative..."
    # Copy cached wheels if available
    if [ -d "$CACHE_DIR/pip-cache" ]; then
        cp "$CACHE_DIR/pip-cache"/*.whl squashfs-root/tmp/ 2>/dev/null
        arch-chroot squashfs-root bash -c 'cd /tmp && for w in *.whl; do pip install --break-system-packages "$w" 2>/dev/null; done'
    fi
}

# Clean up
rm -rf squashfs-root/tmp/*.whl squashfs-root/tmp/install-fastagent.sh
rm -rf squashfs-root/root/.cache

# Rebuild squashfs
echo "Rebuilding squashfs..."
rm "$SQUASHFS"
mksquashfs squashfs-root "$SQUASHFS" -comp xz -noappend

# Rebuild ISO
ISO_DATE=$(date +%Y%m%d-%H%M%S)
NEW_ISO="$SCRIPT_DIR/isos/arch-ai-installer-${ISO_DATE}.iso"

echo "Creating new ISO..."
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -joliet \
    -joliet-long \
    -rational-rock \
    -volid "ARCH_$(date +%Y%m)" \
    -eltorito-boot boot/syslinux/isolinux.bin \
    -eltorito-catalog boot/syslinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -isohybrid-mbr boot/syslinux/isohdpfx.bin \
    -eltorito-alt-boot \
    -e EFI/archiso/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "$NEW_ISO" \
    .

# Clean up
cd "$SCRIPT_DIR"
rm -rf "$WORK_DIR"

if [ -f "$NEW_ISO" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Patched ISO created: $NEW_ISO"
    echo "Size: $(du -h "$NEW_ISO" | cut -f1)"
    echo "Time saved: ~10 minutes vs full rebuild!"
    echo "═══════════════════════════════════════════════════════════"
else
    echo "Error: Failed to create ISO"
    exit 1
fi