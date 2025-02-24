#!/bin/bash
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
echo -e "\n\033[1;32m[1/14] Настройка сети\033[0m"
affirm "Настройте проводное соединение (dhcpcd)?" && dhcpcd

# Шаг 2: Разделение диска
echo -e "\n\033[1;32m[2/14] Разделение диска\033[0m"
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
echo -e "\n\033[1;32m[3/14] Создание файловых систем\033[0m"
mkfs.fat -F32 "${DISK}1"
mkswap "${DISK}2" && swapon "${DISK}2"
mkfs.ext4 "${DISK}3"

# Шаг 4: Монтирование
echo -e "\n\033[1;32m[4/14] Монтирование\033[0m"
mkdir -p /mnt/gentoo
mount "${DISK}3" /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount "${DISK}1" /mnt/gentoo/boot/efi

# Шаг 5: Загрузка Stage3
echo -e "\n\033[1;32m[5/14] Загрузка Stage3\033[0m"
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
echo -e "\n\033[1;32m[6/14] Копирование сетевых настроек\033[0m"
cp /etc/resolv.conf /mnt/gentoo/etc/
if [ -d /etc/NetworkManager/system-connections ]; then
    mkdir -p /mnt/gentoo/etc/NetworkManager/
    cp -r /etc/NetworkManager/system-connections /mnt/gentoo/etc/NetworkManager/
fi

# Шаг 7: Chroot
echo -e "\n\033[1;32m[7/14] Вход в chroot\033[0m"
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev

chroot /mnt/gentoo /bin/bash << 'EOF'

# Шаг 8: Обновление системы и установка пакетов
echo -e "\n\033[1;32m[8/14] Обновление системы и установка пакетов\033[0m"
emerge-webrsync
echo "Выберите пакеты для установки:"
echo "1. sys-boot/grub"
echo "2. sys-kernel/gentoo-sources"
echo "3. sys-apps/systemd"
echo "4. sys-fs/e2fsprogs"
echo "5. sys-fs/udev"
echo "6. sys-fs/udev-init-scripts"
read -p "Введите номера пакетов для установки (разделенные пробелами): " PACKAGES
emerge --update --deep --newuse $PACKAGES

# Шаг 9: Настройка fstab
echo -e "\n\033[1;32m[9/14] Настройка fstab\033[0m"
echo "/dev/sda3 / ext4 defaults 0 1" >> /etc/fstab
echo "/dev/sda2 none swap sw 0 0" >> /etc/fstab
echo "/dev/sda1 /boot/efi vfat defaults 0 1" >> /etc/fstab

# Шаг 10: Установка и настройка bootloaderа
echo -e "\n\033[1;32m[10/14] Установка и настройка GRUB\033[0m"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Шаг 11: Настройка часового пояса
echo -e "\n\033[1;32m[11/14] Настройка часового пояса\033[0m"
echo "Выберите часовой пояс:"
echo "1. Москва"
echo "2. Киев"
echo "3. Минск"
read -p "Введите номер часового пояса: " TIMEZONE
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
        echo "Неверный выбор!" && exit 1
        ;;
esac
hwclock --systohc

# Шаг 12: Настройка имени хоста
echo -e "\n\033[1;32m[12/14] Настройка имени хоста\033[0m"
read -p "Введите имя хоста: " HOSTNAME
echo "$HOSTNAME" > /etc/hostname

# Шаг 13: Настройка локали
echo -e "\n\033[1;32m[13/14] Настройка локали\033[0m"
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set ru_RU.UTF-8
env-update && source /etc/profile

# Шаг 14: Выход из chroot и очистка
echo -e "\n\033[1;32m[14/14] Выход из chroot и очистка\033[0m"
exit

EOF

# Размонтирование
echo -e "\nРазмонтирование файловых систем..."
umount -R /mnt/gentoo/dev
umount -R /mnt/gentoo/sys
umount -R /mnt/gentoo/proc
umount /mnt/gentoo/boot/efi
umount /mnt/gentoo

# Последнее сообщение
echo -e "\n\033[1;32mУстановка завершена! Теперь вы можете перезагрузить систему.\033[0m"
