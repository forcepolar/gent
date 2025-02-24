#!/bin/bash
set -e

# Konfiguratsiya
cd /mnt
STAGE3_FILE="stage3-amd64-desktop-systemd-20250223T170333Z.tar.xz"
STAGE3_URL="https://mirror.yandex.ru/gentoo-distfiles/releases/amd64/autobuilds/current-stage3-amd64-desktop-systemd/$STAGE3_FILE"

# Proverka root i zavisimostey
if [ "$EUID" -ne 0 ]; then
    echo "Zapustite skript ot imeni root!"
    exit 1
fi

# Funktsiya podtverzhdeniya
affirm() {
    local prompt="$1"
    read -n 1 -r -p "$prompt (Y/n): " REPLY
    echo
    if ! [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
        exit 1
    fi
}

# Shag 1: Nastroyka seti
echo -e "\n\033[1;32m[1/13] Nastroyka seti\033[0m"
affirm "Nastroyte provodnoe soedinenie (dhcpcd)?" && dhcpcd

# Shag 2: Razdelenie diska
echo -e "\n\033[1;32m[2/13] Razdelenie diska\033[0m"
lsblk
read -p "Vvedite disk dlya ustanovki (naprimer, /dev/sda): " DISK
affirm "Razdelit disk $DISK? VSE DANNYE BUDUT UDALeny!" && {
    parted "$DISK" mklabel gpt
    parted "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted "$DISK" set 1 esp on
    parted "$DISK" mkpart primary linux-swap 513MiB 4.5GiB
    parted "$DISK" mkpart primary ext4 4.5GiB 100%
}

# Shag 3: Sozdanie faylovih sistem
echo -e "\n\033[1;32m[3/13] Sozdanie faylovih sistem\033[0m"
mkfs.fat -F32 "${DISK}1"
mkswap "${DISK}2" && swapon "${DISK}2"
mkfs.ext4 "${DISK}3"

# Shag 4: Montirovanie
echo -e "\n\033[1;32m[4/13] Montirovanie\033[0m"
mkdir -p /mnt/gentoo
mount "${DISK}3" /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount "${DISK}1" /mnt/gentoo/boot/efi

# Shag 5: Zagruzka Stage3
echo -e "\n\033[1;32m[5/13] Zagruzka Stage3\033[0m"
cd /mnt/gentoo
wget -O stage3.tar.xz "$STAGE3_URL" || {
    echo "Oshibka pri zagruzke Stage3!"
    exit 1
}
tar xpvf stage3.tar.xz --xattrs-include='*' --numeric-owner || {
    echo "Oshibka pri razpakovanii Stage3!"
    exit 1
}

# Shag 6: Kopirovanie setevih nastroyek
echo -e "\n\033[1;32m[6/13] Kopirovanie setevih nastroyek\033[0m"
cp /etc/resolv.conf /mnt/gentoo/etc/
if [ -d /etc/NetworkManager/system-connections ]; then
    mkdir -p /mnt/gentoo/etc/NetworkManager/
    cp -r /etc/NetworkManager/system-connections /mnt/gentoo/etc/NetworkManager/
fi

# Shag 7: Chroot
echo -e "\n\033[1;32m[7/13] Vhod v chroot\033[0m"
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev

chroot /mnt/gentoo /bin/bash << 'EOF'

# Shag 8: Obnovlenie sistemy i ustanovka paketov
echo -e "\n\033[1;32m[8/13] Obnovlenie sistemy i ustanovka paketov\033[0m"
emerge-webrsync
echo "Vyberite pakety dlya ustanovki:"
echo "1. sys-boot/grub"
echo "2. sys-kernel/gentoo-sources"
echo "3. sys-apps/systemd"
read -p "Vvedite nomera paketov dlya ustanovki (razdelenie probelami): " PACKAGES
emerge --update --deep --newuse $PACKAGES

# Shag 9: Nastroyka fstab
echo -e "\n\033[1;32m[9/13] Nastroyka fstab\033[0m"
echo "/dev/sda3 / ext4 defaults 0 1" >> /etc/fstab
echo "/dev/sda2 none swap sw 0 0" >> /etc/fstab
echo "/dev/sda1 /boot/efi vfat defaults 0 1" >> /etc/fstab

# Shag 10: Ustanovka i nastroyka bootloadera
echo -e "\n\033[1;32m[10/13] Ustanovka i nastroyka GRUB\033[0m"
grub-install --target=i386-pc /dev/sda  # Ustanovite na nuzhnyi disk
grub-mkconfig -o /boot/grub/grub.cfg

# Shag 11: Nastroyka chasovogo poiasa
echo -e "\n\033[1;32m[11/13] Nastroyka chasovogo poiasa\033[0m"
echo "Vyberite chasovoi poias:"
echo "1. Moskva"
echo "2. Kiev"
echo "3. Minsk"
read -p "Vvedite nomer chasovogo poiasa: " TIMEZONE
case $TIMEZONE in
    1)
        ln -sf /usr/share/zoneinfo/Moscow /etc/localtime
        ;;
    2)
        ln -sf /usr/share/zoneinfo/Kiev /etc/localtime
        ;;
    3)
        ln -sf /usr/share/zoneinfo/Minsk /etc/localtime
        ;;
    *)
        echo "Nevernyi vybor!" && exit 1
        ;;
esac
hwclock --systohc

# Shag 12: Nastroyka imeni hosta
echo -e "\n\033[1;32m[12/13] Nastroyka imeni hosta\033[0m"
read -p "Vvedite ime hosta: " HOSTNAME
echo "$HOSTNAME" > /etc/hostname

# Shag 13: Vihod iz chroot i ochistka
echo -e "\n\033[1;32m[13/13] Vihod iz chroot i ochistka\033[0m"
exit

EOF

# Razmontirovanie
echo -e "\nRazmontirovanie faylovih sistem..."
umount -R /mnt/gentoo/dev
umount -R /mnt/gentoo/sys
umount -R /mnt/gentoo/proc
umount /mnt/gentoo/boot/efi
umount /mnt/gentoo

# Poslednee soobshchenie
echo -e "\n\033[1;32mUstanovka kompleksa! Teper vy mozhete perезагрузit sistem.\033[0m"
