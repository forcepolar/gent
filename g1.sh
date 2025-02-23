#!/bin/bash
set -e

# Configuration
MIRROR="https://mirrors.mit.edu/gentoo-distfiles"
STAGE3_INDEX_URL="$MIRROR/releases/amd64/autobuilds/latest-stage3-amd64-desktop-systemd.txt"

# Check root and dependencies
if [ "$EUID" -ne 0 ]; then
  echo "Run the script as root!"
  exit 1
fi

for cmd in parted wget tar chroot; do
  if ! command -v $cmd &> /dev/null; then
    echo "Error: $cmd not installed!"
    exit 1
  fi
done

# Confirmation function
affirm() {
  read -p "$1 (Y/n): " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

# Step 1: Network setup
echo -e "\n\033[1;32m[1/13] Network setup\033[0m"
affirm "Set up wired connection (dhcpcd)?" && dhcpcd

# Step 2: Disk partitioning
echo -e "\n\033[1;32m[2/13] Disk partitioning\033[0m"
lsblk
read -p "Enter disk for installation (e.g. /dev/sda): " DISK
affirm "Partition disk ${DISK}? ALL DATA WILL BE DELETED!" && {
  parted ${DISK} mklabel gpt
  parted ${DISK} mkpart ESP fat32 1MiB 513MiB
  parted ${DISK} set 1 esp on
  parted ${DISK} mkpart primary linux-swap 513MiB 4.5GiB
  parted ${DISK} mkpart primary ext4 4.5GiB 100%
}

# Step 3: File systems
echo -e "\n\033[1;32m[3/13] Creating file systems\033[0m"
mkfs.fat -F32 ${DISK}1
mkswap ${DISK}2 && swapon ${DISK}2
mkfs.ext4 ${DISK}3

# Step 4: Mounting
echo -e "\n\033[1;32m[4/13] Mounting\033[0m"
mkdir -p /mnt/gentoo
mount ${DISK}3 /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount ${DISK}1 /mnt/gentoo/boot/efi

# Step 5: Downloading Stage3 (automatic latest version fetch)
echo -e "\n\033[1;32m[5/13] Downloading Stage3\033[0m"
cd /mnt/gentoo
LATEST_STAGE3=$(wget -qO- "$STAGE3_INDEX_URL" | grep -v '^#' | awk '{print $1}' | head -1)

if [ -z "$LATEST_STAGE3" ]; then
  echo "Error: Failed to fetch latest Stage3!"
  exit 1
fi

STAGE3_FULL_URL="$MIRROR/releases/amd64/autobuilds/$LATEST_STAGE3"
echo "Downloading: $STAGE3_FULL_URL"

wget -O stage3.tar.xz "$STAGE3_FULL_URL" || {
  echo "Error downloading Stage3!"
  exit 1
}

tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner || {
  echo "Error extracting Stage3!"
  exit 1
}

# Step 6: Copying network settings
echo -e "\n\033[1;32m[6/13] Copying network settings\033[0m"
cp /etc/resolv.conf /mnt/gentoo/etc/
if [ -d /etc/NetworkManager/system-connections ]; then
  mkdir -p /mnt/gentoo/etc/NetworkManager/
  cp -r /etc/NetworkManager/system-connections /mnt/gentoo/etc/NetworkManager/
fi

# Step 7: Chroot
echo -e "\n\033[1;32m[7/13] Entering chroot\033[0m"
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev

chroot /mnt/gentoo /bin/bash
