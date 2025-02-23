#!/bin/bash
set -e

# Konfiguratsiya
MIRROR="https://mirror.yandex.ru/gentoo-distfiles"
STAGE3_URL="https://mirror.yandex.ru/gentoo-distfiles/releases/amd64/autobuilds/current-stage3-amd64-desktop-systemd/stage3-amd64-desktop-systemd-20250216T164837Z.tar.xz"

# Proverka root i zavisimostey
if [ "$EUID" -ne 0 ]; then
  echo "Zapustite skript ot root!"
  exit 1
fi

for cmd in parted wget tar chroot; do
  if ! command -v $cmd &> /dev/null; then
    echo "Oshibka: $cmd ne ustanovlen!"
    exit 1
  fi
done

# Funktsiya podtverzhdeniya
confirm() {
  read -p "$1 (Y/n): " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

# Shag 1: Nastroyka seti
echo -e "\n\033[1;32m[1/13] Nastroyka seti\033[0m"
confirm "Nastroyti provodnoe podklyuchenie (dhcpcd)?" && {
  dhcpcd || {
    echo "Oshibka nastroyki seti!"
    exit 1
  }
}

# Shag 2: Razmetka diska
echo -e "\n\033[1;32m[2/13] Razmetka diska\033[0m"
lsblk
read -p "Ukazhite disk dlya ustanovki (naprimer /dev/sda): " DISK
confirm "Razmetit disk ${DISK}? VSE DANNYE BUDUT UDALeny!" && {
  parted ${DISK} mklabel gpt
  parted ${DISK} mkpart ESP fat32 1MiB 513MiB
  parted ${DISK} set 1 esp on
  parted ${DISK} mkpart primary linux-swap 513MiB 4.5GiB
  parted ${DISK} mkpart primary ext4 4.5GiB 100%
}

# Shag 3: Faylovye sistemy
echo -e "\n\033[1;32m[3/13] Sozdaniye FS\033[0m"
mkfs.fat -F32 ${DISK}1 || exit 1
mkswap ${DISK}2 || exit 1
swapon ${DISK}2 || exit 1
mkfs.ext4 ${DISK}3 || exit 1

# Shag 4: Montirovaniye
echo -e "\n\033[1;32m[4/13] Montirovaniye\033[0m"
mkdir -p /mnt/gentoo
mount ${DISK}3 /mnt/gentoo || exit 1
mkdir -p /mnt/gentoo/boot/efi
mount ${DISK}1 /mnt/gentoo/boot/efi || exit 1

# Shag 5: Stage3 (ispravlenniy URL)
echo -e "\n\033[1;32m[5/13] Zagruzka Stage3\033[0m"
cd /mnt/gentoo
STAGE3_FULL_URL="${MIRROR}/${STAGE3_PATH}"
LATEST_STAGE3=$(wget -qO- ${STAGE3_FULL_URL} | grep -v ^# | awk '{print $1}' | head -1)
wget "${MIRROR}/releases/amd64/autobuilds/${LATEST_STAGE3}" -O stage3.tar.xz || {
  echo "Oshibka zagruzki Stage3!"
  exit 1
}
tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner || {
  echo "Oshibka raspakovki Stage3!"
  exit 1
}

# Shag 6: Kopirovaniye nastroyek seti
echo -e "\n\033[1;32m[6/13] Kopirovaniye nastroyek seti\033[0m"
cp /etc/resolv.conf /mnt/gentoo/etc/ || exit 1
if [ -f /etc/NetworkManager/system-connections ]; then
  mkdir -p /mnt/gentoo/etc/NetworkManager/
  cp -r /etc/NetworkManager/system-connections /mnt/gentoo/etc/NetworkManager/ || exit 1
fi

# Shag 7: Chroot
echo -e "\n\033[1;32m[
