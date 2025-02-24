#!/bin/bash

# verison 4:45 

set -e

# Конфигурация
cd /mnt
STAGE3_FILE="stage3-amd64-desktop-systemd-20250223T170333Z.tar.xz"
STAGE3_URL="https://mirror.yandex.ru/gentoo-distfiles/releases/amd64/autobuilds/current-stage3-amd64-desktop-systemd/$STAGE3_FILE"

# Проверка root и зависимостей
if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт от имени root!"
    exit 1
fi

# Функция подтверждения
affirm() {
    local prompt="$1"
    read -n 1 -r -p "$prompt (Y/n): " REPLY
    echo
    if ! [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
        exit 1
    fi
}

# Шаг 1: Настройка сети
echo -e "\n\033[1;32m[1/20] Настройка сети\033[0m"
affirm "Настройте проводное соединение (dhcpcd)?" && dhcpcd

# Шаг 2: Разделение диска
echo -e "\n\033[1;32m[2/20] Разделение диска\033[0m"
lsblk
read -p "Введите диск для установки (например, /dev/sda): " DISK
affirm "Разделить диск $DISK? ВСЕ ДАННЫЕ БУДУТ УДАЛЕНЫ!" && {
    parted "$DISK" mklabel gpt
    parted "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted "$DISK" set 1 esp on
    parted "$DISK" mkpart primary linux-swap 513MiB 4.5GiB
    parted "$DISK" mkpart primary ext4 4.5GiB 100%
}

# Шаг 3: Создание файловых систем
echo -e "\n\033[1;32m[3/20] Создание файловых систем\033[0m"
mkfs.fat -F32 "${DISK}1"
mkswap "${DISK}2" && swapon "${DISK}2"
mkfs.ext4 "${DISK}3"

# Шаг 4: Монтирование
echo -e "\n\033[1;32m[4/20] Монтирование\033[0m"
mkdir -p /mnt/gentoo
mount "${DISK}3" /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount "${DISK}1" /mnt/gentoo/boot/efi

# Шаг 5: Загрузка Stage3
echo -e "\n\033[1;32m[5/20] Загрузка Stage3\033[0m"
cd /mnt/gentoo
wget -O stage3.tar.xz "$STAGE3_URL" || {
    echo "Ошибка при загрузке Stage3!"
    exit 1
}
tar xpvf stage3.tar.xz --xattrs-include='*' --numeric-owner || {
    echo "Ошибка при распаковке Stage3!"
    exit 1
}

# Шаг 6: Копирование сетевых настроек
echo -e "\n\033[1;32m[6/20] Копирование сетевых настроек\033[0m"
cp /etc/resolv.conf /mnt/gentoo/etc/
if [ -d /etc/NetworkManager/system-connections ]; then
    mkdir -p /mnt/gentoo/etc/NetworkManager/
    cp -r /etc/NetworkManager/system-connections /mnt/gentoo/etc/NetworkManager/
fi

# Шаг 7: Chroot
echo -e "\n\033[1;32m[7/20] Вход в chroot\033[0m"
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev

chroot /mnt/gentoo /bin/bash << 'EOF'

# Шаг 8: Обновление системы и установка пакетов
echo -e "\n\033[1;32m[8/20] Обновление системы и установка пакетов\033[0m"
emerge-webrsync
emerge --update --deep --newuse @world

# Шаг 9: Установка ядра
echo -e "\n\033[1;32m[9/20] Установка ядра\033[0m"
emerge --update --deep --newuse sys-kernel/gentoo-sources
cd /usr/src/linux
make menuconfig
make -j$(nproc)
make install
cd /boot
mkinitramfs -o initramfs.gz /boot/vmlinuz

# Шаг 10: Установка драйверов
echo -e "\n\033[1;32m[10/20] Установка драйверов\033[0m"
emerge --update --deep --newuse x11-drivers/xf86-video-intel
emerge --update --deep --newuse x11-drivers/xf86-video-nouveau
emerge --update --deep --newuse x11-drivers/xf86-video-ati

# Шаг 11: Установка системы инициализации
echo -e "\n\033[1;32m[11/20] Установка системы инициализации\033[0m"
emerge --update --deep --newuse sys-apps/systemd
systemctl enable systemd-networkd
systemctl enable systemd-resolved

# Шаг 12: Установка других необходимых пакетов
echo -e "\n\033[1;32m[12/20] Установка других необходимых пакетов\033[0m"
emerge --update --deep --newuse app-editors/nano
emerge --update --deep --newuse app-text/less
emerge --update --deep --newuse net-misc/wget
emerge --update --deep --newuse net-misc/curl

# Шаг 13: Настройка сети
echo -e "\n\033[1;32m[13/20] Настройка сети\033[0m"
echo "Введите имя хоста: "
read HOSTNAME
echo "$HOSTNAME" > /etc/hostname
echo "Введите имя пользователя: "
read USERNAME
useradd -m -s /bin/bash "$USERNAME"
echo "Введите пароль для пользователя $USERNAME: "
read -s PASSWORD
echo "$USERNAME:$PASSWORD" | chpasswd

# Шаг 14: Настройка локали
echo -e "\n\033[1;32m[14/20] Настройка локали\033[0m"
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set ru_RU.UTF-8
env-update && source /etc/profile

# Шаг 15: Настройка часового пояса
echo -e "\n\033[1;32m[15/20] Настройка часового пояса\033[0m"
echo "Введите часовой пояс: "
read TIMEZONE
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Шаг 16: Установка bootloaderа
echo -e "\n\033[1;32m[16/20] Установка bootloaderа\033[0m"
emerge --update --deep --newuse sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Шаг 17: Настройка файрвола
echo -e "\n\033[1;32m[17/20] Настройка файрвола\033[0m"
emerge --update --deep --newuse net-firewall/iptables
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
service iptables save
service iptables restart

# Шаг 18: Настройка SELinux
echo -e "\n\033[1;32m[18/20] Настройка SELinux\033[0m"
emerge --update --deep --newuse sec-policy/selinux-base
selinux-activate

# Шаг 19: Настройка системы
echo -e "\n
