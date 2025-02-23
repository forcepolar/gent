#!/bin/bash
set -e

# Проверка, что скрипт запущен от root
if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен быть запущен от root"
    exit 1
fi

# Проверка наличия whiptail (если нет, устанавливаем dialog)
if ! command -v whiptail &> /dev/null; then
    echo "Устанавливаем dialog..."
    pacman -Sy --noconfirm dialog
    alias whiptail=dialog
fi

# Выбор диска
DISK=$(whiptail --inputbox "Введите диск для установки (по умолчанию /dev/sdb):" 10 60 /dev/sdb 3>&1 1>&2 2>&3)
if [ -z "$DISK" ]; then
    DISK="/dev/sdb"
fi

# Подтверждение разметки диска
if whiptail --yesno "Разметить диск автоматически?" 10 60; then
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
cp -r /etc/systemd/network /mnt/etc/systemd/network
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Установка и компиляция ядра
emerge -av sys-kernel/gentoo-sources
cd /usr/src/linux
make menuconfig
make -j$(nproc)
make modules_install
make install

# Выбор загрузчика
if whiptail --yesno "Хотите использовать GRUB вместо systemd-boot?" 10 60; then
    emerge -av grub
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg
else
    bootctl install
    echo -e "title Gentoo Linux\nlinux /vmlinuz\ninitrd /boot/initramfs\noptions root=${DISK}3 rw" > /boot/loader/entries/gentoo.conf
fi

# Установка Xorg, bspwm и драйверов NVIDIA
echo "Установка Xorg, bspwm и NVIDIA..."
emerge -av xorg-server xorg-xinit bspwm sxhkd dmenu alacritty nvidia-drivers
mkdir -p /home/ervin
echo "exec bspwm" > /home/ervin/.xinitrc
chown ervin:ervin /home/ervin/.xinitrc

# Установка пароля для root
whiptail --msgbox "Установите пароль для root" 10 60
passwd

# Установка пользователя ervin
useradd -m -G wheel -s /bin/bash ervin
whiptail --msgbox "Установите пароль для пользователя ervin" 10 60
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
