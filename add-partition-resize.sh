#!/bin/bash
# This script adds partition resize instructions to the custom Arch ISO
# It should be sourced from docker-build.sh

# Create the partition resize script
cat > /build/profile/airootfs/usr/local/bin/resize-linux-for-windows << 'RESIZESCRIPT'
#!/bin/bash
# Resize nvme1n1p3 (Linux) from ~1991GB to 1500GB to make room for Windows

set -e

echo "═══════════════════════════════════════════════════════════"
echo "    PARTITION RESIZE SCRIPT FOR WINDOWS DUAL BOOT"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "This script will:"
echo "  1. Shrink /dev/nvme1n1p3 (Linux) from 1991GB to 1500GB"
echo "  2. Create /dev/nvme1n1p5 (Windows) with 300GB"
echo "  3. Leave space for Windows installation"
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
echo "Partition layout:"
parted /dev/nvme1n1 print
echo ""
echo "Next steps:"
echo "  1. Reboot and remove this USB"
echo "  2. Boot into your Linux system to verify everything works"
echo "  3. Boot Windows installer"
echo "  4. Install Windows to the new partition (should show as ~300GB unformatted)"
echo ""
echo "Press any key to view detailed partition info..."
read -n 1
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT
RESIZESCRIPT
chmod +x /build/profile/airootfs/usr/local/bin/resize-linux-for-windows

# Create a simpler helper command
ln -sf /usr/local/bin/resize-linux-for-windows /build/profile/airootfs/usr/bin/resize-for-windows

# Create welcome message that shows on boot
cat > /build/profile/airootfs/etc/motd << 'MOTD'

╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║       ARCH LINUX LIVE USB - PARTITION RESIZE EDITION             ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

This ISO contains tools to resize your Linux partition and prepare
space for a Windows dual boot installation.

📋 TASK: Resize /dev/nvme1n1p3 from 1991GB → 1500GB for Windows

═══════════════════════════════════════════════════════════════════

🔧 COMMANDS AVAILABLE:

  resize-for-windows    - Run the automated partition resize script
  lsblk                 - View current disk layout
  parted /dev/nvme1n1   - Manual partition management

═══════════════════════════════════════════════════════════════════

📖 DETAILED PROCEDURE (if you want to do it manually):

1. Check filesystem:
   e2fsck -f /dev/nvme1n1p3

2. Shrink filesystem to 1500GB:
   resize2fs /dev/nvme1n1p3 1500G

3. Shrink partition:
   parted /dev/nvme1n1
   > resizepart 3
   > 1505GB
   > yes
   > quit

4. Create Windows partition (300GB):
   parted /dev/nvme1n1 mkpart primary ntfs 1505GB 1805GB
   parted /dev/nvme1n1 set 5 msftdata on

5. Verify:
   parted /dev/nvme1n1 print
   lsblk

═══════════════════════════════════════════════════════════════════

⚠️  IMPORTANT NOTES:
  • Make sure you've backed up important data
  • The filesystem must be unmounted (it is, since you're booted from USB)
  • After resizing, reboot and verify Linux still works
  • Then install Windows to the new 300GB partition

═══════════════════════════════════════════════════════════════════

🚀 Quick start: Type 'resize-for-windows' and press Enter

MOTD

# Update the AI installer welcome message to mention partition tools
cat > /build/profile/airootfs/root/.partition-resize-notice << 'NOTICE'

╔══════════════════════════════════════════════════════════════════╗
║                  SPECIAL BOOT: PARTITION RESIZE                  ║
╚══════════════════════════════════════════════════════════════════╝

This boot includes partition management tools for dual boot setup.

Type 'resize-for-windows' to start the automated partition resize,
or use the AI assistant for guidance!

NOTICE
