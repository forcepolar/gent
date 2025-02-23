#!/bin/bash
set -e

# Configuration
MIRROR="https://mirror.yandex.ru/gentoo-distfiles"
STAGE3_PATH="releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt"

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
confirm() {
  read -p "$1 (Y/n): " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

# Step 1: Network setup
echo -e "\n\033[1;32m[1/13] Network setup\033[0m"
confirm "Set up wired connection (dhcpcd)?" && {
  dhcpcd || {
    echo "Error setting up network!"
    exit 1
  }
}

# Step 2: Disk partitioning
echo -e "\n\033[1;32m[2/13] Disk partitioning\033[0m"
lsblk
read -p "Enter disk for installation (e.g. /dev/sda): " DISK
confirm "Partition disk ${DISK}? ALL DATA WILL BE DELETED!" && {
  parted ${DISK} mklabel gpt
  parted ${DISK} mkpart ESP fat32 1MiB 513MiB
  parted ${DISK} set 1 esp on
  parted ${DISK} mkpart primary linux-swap 513MiB 4.5GiB
  parted ${DISK} mkpart primary ext4 4.5GiB 100%
}

# Step 3: File systems
echo -e "\n\033[1;32m[3/13] Creating file systems\033[0m"
mkfs.fat -F32 ${DISK}1 || exit 1
mkswap ${DISK}2 || exit 1
swapon ${DISK}2 || exit 1
mkfs.ext4 ${DISK}3 || exit 1

# Step 4: Mounting
echo -e "\n\033[1;32m[4/13] Mounting\033[0m"
mkdir -p /mnt/gentoo
mount ${DISK}3 /mnt/gentoo || exit 1
mkdir -p /mnt/gentoo/boot/efi
mount ${DISK}1 /mnt/gentoo/boot/efi || exit 1

# Step 5: Stage3 (updated URL)
echo -e "\n\033[1;32m[5/13] Downloading Stage3\033[0m"
cd /mnt/gentoo
STAGE3_FULL_URL="${MIRROR}/${STAGE3_PATH}"
LATEST_STAGE3=$(wget -qO- ${STAGE3_FULL_URL} | grep -v ^# | awk '{print $1}' | head -1)
wget "${MIRROR}/releases/amd64/autobuilds/${LATEST_STAGE3}" -O stage3.tar.xz || {
  echo "Error downloading Stage3!"
  exit 1
}
tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner || {
  echo "Error extracting Stage3!"
  exit 1
}

# Step 6: Copying network settings
echo -e "\n\033[1;32m[6/13] Copying network settings\033[0m"
cp /etc/resolv.conf /mnt/gentoo/etc/ || exit 1
if [ -f /etc/NetworkManager/system-connections ]; then
  mkdir -p /mnt/gentoo/etc/NetworkManager/
  cp -r /etc/NetworkManager/system-connections /mnt/gentoo/etc/NetworkManager/ || exit 1
fi

# Step 7: Chroot
echo -e "\n\033[1;32m[7/13] Chroot\033[0m"
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev

# Step 8: System setup
echo -e "\n\033[1;32m[8/13] Basic setup\033[0m
