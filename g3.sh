#!/bin/bash
set -e

# Proverka, chto skript zapushchen ot root
if [ "$(id -u)" -ne 0 ]; then
    echo "Etot skript dolzhen byt' zapushchen ot root"
    exit 1
fi

# Proverka nalichiya whiptail (esli net, ustanavlivaem dialog)
if ! command -v whiptail &> /dev/null; then
    echo "Ustanavlivaem dialog..."
    pacman -Sy --noconfirm dialog
    alias whiptail=dialog
fi

# Vybor diska
DISK=$(whiptail --inputbox "Vvedite disk dlya ustanovki (po umolchaniyu /dev/sdb):" 10 60 /dev/sdb 3>&1 1>&2 2>&3)
if [ -z "$DISK" ]; then
    DISK="/dev/sdb"
fi

# Podtverzhdenie razmetki diska
if whiptail --yesno "Razmetit' disk avtonomno?" 10 60; then
    parted "$DISK" mklabel gpt
    parted "$DISK" mkpart ESP fat32 1MiB 512MiB
    parted "$DISK" set 1 boot on
    parted "$DISK" mkpart primary linux-swap 512MiB 4.5GiB
    parted "$DISK" mkpart primary ext4 4.5GiB 100%
    mkfs.fat -F32 "${DISK}1"
    mkswap "${DISK}2" && swapon "${DISK}2"
    mkfs.ext4 "${DISK}3"
fi

# Montirovanie razdelov
mount "${DISK}3" /mnt
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot

# Step: Download Stage3
cd /mnt
STAGE3_FILE="stage3-amd64-desktop-systemd-20250216T164837Z.tar.xz"
STAGE3_URL="https://mirror.yandex.ru/gentoo-distfiles/releases/amd64/autobuilds/current-stage3-amd64-desktop-systemd/$STAGE3_FILE"

echo "Downloading $STAGE3_FILE..."
curl -O "$STAGE3_URL" || {
  echo "Error downloading Stage3!"
  exit 1
}

tar xpvf "$STAGE3_FILE" --xattrs-include='*.*' --numeric-owner || {
  echo "Error extracting Stage3!"
  exit 1
}

# Nastroika chroot
cp -L /etc/resolv.conf /mnt/etc/
mount -t proc /proc /mnt/proc
mount --rbind /sys /mnt/sys
mount --rbind /dev /mnt/dev

# Peredacha peremennoy DISK vnutr' chroot
echo "DISK=${DISK}" > /mnt/root/install_disk

# Vkhod v chroot i vypolnenie dal'neyshey ustanovki
chroot /mnt /bin/bash <<'EOF'
source /etc/profile
export PS1="(chroot) \$PS1"

# Import peremennoy DISK
if [ -f /root/install_disk ]; then
    source /root/install_disk
else
    echo "Ne udalos' importirovat' peremennuyu DISK"
    exit 1
fi

# Obnovlenie portezev i sistemy
emerge-webrsync
emerge --sync
emerge -avuDN @world

# Nastroika vremeni i lokaley
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" > /etc/timezone
emerge --config sys-libs/timezone-data

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo 'LANG="en_US.UTF-8"' > /etc/locale.conf

# Nastroika bezopasnosti paroly
echo "min=1,1,1,1,1" > /etc/security/passwdqc.conf

# Nastroika hostname i seti
echo "halaxygentoo" > /etc/hostname
emerge -av systemd-networkd
systemctl enable systemd-networkd systemd-resolved
cp -r /etc/systemd/network /mnt/etc/systemd/network
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Ustanovka i kompilyatsiya yadra
emerge -av sys-kernel/gentoo-sources
cd /usr/src/linux
make menuconfig
make -j$(nproc)
make modules_install
make install

# Vybor zagruzchika
if whiptail --yesno "Khotite ispol'zovat' GRUB vmesto systemd-boot?" 10 60
