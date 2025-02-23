#!/bin/bash
set -e

# Проверка, что скрипт запущен от root
if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен от root"
    exit 1
fi

# Функция для запроса подтверждения
yes_no() {
    while true; do
        read -p "$1 (Y/n): " choice
        case "$choice" in
            Y|y|"") return 0 ;;
            N|n) return 1 ;;
            *) echo "Пожалуйста, введите Y или n" ;;
        esac
    done
}

# Настройка времени
echo "Настройка времени..."
timedatectl set-ntp true

# Разметка диска
lsblk
read -p "Введите диск для установки (по умолчанию /dev/sdb): " DISK
if [ -z "$DISK" ]; then
    DISK="/dev/sdb"
fi

if yes_no "Разметить диск автоматически?"; then
    parted "$DISK" mklabel gpt
    parted "$DISK" mkpart ESP fat32 1MiB 512MiB
    parted "$DISK" set 1 boot on
    parted "$DISK" mkpart primary linux-swap 512MiB 4.5GiB
    parted "$DISK" mkpart primary ext4 4.5GiB 100%

    mkfs.fat -F32 "${DISK}1"
    mkswap "${DISK}2" && swapon "${DISK}2"
    mkfs.ext4 "${DISK}3"
fi

# Монтирование разделов
mount "${DISK}3" /mnt
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot

# Загрузка Stage3
cd /mnt
STAGE3_FILE="stage3-amd64-systemd-latest.tar.xz"
echo "Загрузка $STAGE3_FILE..."
curl -O "https://mirror.yandex.ru/gentoo-distfiles/$STAGE3_FILE"
tar xpvf "$STAGE3_FILE" --xattrs-include='*.*' --numeric-owner

# Настройка chroot
cp -L /etc/resolv.conf /mnt/etc/
mount -t proc /proc /mnt/proc
mount --rbind /sys /mnt/sys
mount --rbind /dev /mnt/dev

# Передача переменной DISK внутрь chroot
echo "DISK=${DISK}" > /mnt/root/install_disk

# Вход в chroot и выполнение дальнейшей установки
chroot /mnt /bin/bash <<'EOF'
source /etc/profile
export PS1="(chroot) \$PS1"

# Импорт переменной DISK
if [ -f /root/install_disk ]; then
    source /root/install_disk
else
    echo "Не удалось импортировать переменную DISK"
    exit 1
fi

# Обновление портежей и системы
emerge-webrsync
emerge --sync
emerge -avuDN @world

# Настройка времени и локали
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" > /etc/timezone
emerge --config sys-libs/timezone-data

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo 'LANG="en_US.UTF-8"' > /etc/locale.conf

# Настройка безопасности паролей
echo "min=1,1,1,1,1" > /etc/security/passwdqc.conf

# Настройка hostname и сети
echo "halaxygentoo" > /etc/hostname
emerge -av systemd-networkd
systemctl enable systemd-networkd systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Установка ядра и генерация initramfs
emerge -av gentoo-kernel-bin
emerge -av dracut
dracut --force

# Установка загрузчика systemd-boot
bootctl install
echo -e "title Gentoo Linux
linux /vmlinuz
initrd /boot/initramfs
options root=${DISK}3 rw" > /boot/loader/entries/gentoo.conf

# Установка Xorg и bspwm
echo "Установка Xorg и bspwm..."
emerge -av xorg-server xorg-xinit bspwm sxhkd dmenu alacritty
mkdir -p /home/ervin
echo "exec bspwm" > /home/ervin/.xinitrc
chown ervin:ervin /home/ervin/.xinitrc

# Установка пароля для root
passwd

# Установка пользователя ervin
useradd -m -G wheel -s /bin/bash ervin
passwd ervin
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

exit
EOF

# Завершение установки
umount -l /mnt/boot
umount -l /mnt/sys
umount -l /mnt/proc
umount -l /mnt/dev
swapoff "${DISK}2"
reboot
