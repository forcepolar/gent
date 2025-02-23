#!/bin/bash
set -e

# Конфигурация
MIRROR="https://mirror.yandex.ru/gentoo-distfiles"
STAGE3_PATH="releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt"

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo "Запустите скрипт от root!"
  exit 1
fi

# Функция подтверждения
confirm() {
  read -p "$1 (Y/n): " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

# Шаг 1: Настройка сети
echo -e "\n\033[1;32m[1/13] Настройка сети\033[0m"
confirm "Настроить проводное подключение (dhcpcd)?" && dhcpcd

# Шаг 2: Разметка диска
echo -e "\n\033[1;32m[2/13] Разметка диска\033[0m"
lsblk
read -p "Укажите диск для установки (например /dev/sda): " DISK
confirm "Разметить диск ${DISK}? ВСЕ ДАННЫЕ БУДУТ УДАЛЕНЫ!" && {
  parted ${DISK} mklabel gpt
  parted ${DISK} mkpart ESP fat32 1MiB 513MiB
  parted ${DISK} set 1 esp on
  parted ${DISK} mkpart primary linux-swap 513MiB 4.5GiB
  parted ${DISK} mkpart primary ext4 4.5GiB 100%
}

# Шаг 3: Файловые системы
echo -e "\n\033[1;32m[3/13] Создание ФС\033[0m"
mkfs.fat -F32 ${DISK}1
mkswap ${DISK}2
swapon ${DISK}2
mkfs.ext4 ${DISK}3

# Шаг 4: Монтирование
echo -e "\n\033[1;32m[4/13] Монтирование\033[0m"
mount ${DISK}3 /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount ${DISK}1 /mnt/gentoo/boot/efi

# Шаг 5: Stage3 (исправленный URL)
echo -e "\n\033[1;32m[5/13] Загрузка Stage3\033[0m"
STAGE3_FULL_URL="${MIRROR}/${STAGE3_PATH}"
wget -qO- ${STAGE3_FULL_URL} | grep -v ^# | awk '{print $1}' | head -1 | {
  read -r url
  wget "${MIRROR}/releases/amd64/autobuilds/${url}" -O stage3.tar.xz
  tar xpvf stage3.tar.xz -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner
}

# Шаг 6: Chroot
echo -e "\n\033[1;32m[6/13] Настройка chroot\033[0m"
cp /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev

# Шаг 7: Настройка системы
echo -e "\n\033[1;32m[7/13] Базовая настройка\033[0m"
chroot /mnt/gentoo /bin/bash <<'EOL'
source /etc/profile
export PS1="(chroot) $PS1"

# Обновление Portage
eselect news read
emerge-webrsync

# Профиль Systemd
eselect profile list
read -p "Номер профиля Systemd: " PROFILE_NUM
eselect profile set ${PROFILE_NUM}

# Обновление системы
emerge --ask --verbose --update --deep --newuse @world
EOL

# Шаг 8: Ядро (добавлена компиляция)
echo -e "\n\033[1;32m[8/13] Установка ядра\033[0m"
confirm "Установить и скомпилировать ядро?" && {
  chroot /mnt/gentoo emerge sys-kernel/gentoo-sources sys-kernel/linux-firmware
  chroot /mnt/gentoo /bin/bash <<'EOL'
  cd /usr/src/linux
  make defconfig
  make -j$(nproc)
  make modules_install
  make install
  emerge sys-kernel/dracut
  dracut --host-only -k /boot/initramfs-$(uname -r).img $(uname -r)
EOL
}

# Шаг 9: Fstab
echo -e "\n\033[1;32m[9/13] Генерация fstab\033[0m"
genfstab -U /mnt/gentoo >> /mnt/gentoo/etc/fstab

# Шаг 10: Загрузчик (исправленные пути)
echo -e "\n\033[1;32m[10/13] Установка загрузчика\033[0m"
chroot /mnt/gentoo bootctl install
KERNEL_VERSION=$(ls /mnt/gentoo/boot | grep vmlinuz | cut -d'-' -f2-)
UUID=$(blkid -s UUID -o value ${DISK}3)
cat <<EOF > /mnt/gentoo/boot/loader/entries/gentoo.conf
title Gentoo Linux
linux /vmlinuz-${KERNEL_VERSION}
initrd /initramfs-${KERNEL_VERSION}.img
options root=UUID=${UUID} rw
EOF

# Шаг 11: Локализация
echo -e "\n\033[1;32m[11/13] Настройка локали\033[0m"
chroot /mnt/gentoo /bin/bash <<'EOL'
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
EOL

# Шаг 12: Пользователь (добавлен sudo)
echo -e "\n\033[1;32m[12/13] Создание пользователя\033[0m"
read -p "Имя пользователя: " USERNAME
chroot /mnt/gentoo useradd -m -G wheel,users,audio,video -s /bin/bash ${USERNAME}
chroot /mnt/gentoo passwd ${USERNAME}
chroot /mnt/gentoo emerge app-admin/sudo
echo "%wheel ALL=(ALL) ALL" >> /mnt/gentoo/etc/sudoers

# Шаг 13: Графическое окружение
echo -e "\n\033[1;32m[13/13] Установка bspwm\033[0m"
confirm "Установить графическое окружение?" && {
  chroot /mnt/gentoo emerge xorg-server bspwm sxhkd alacritty lightdm
  chroot /mnt/gentoo systemctl enable lightdm
}

echo -e "\n\033[1;32mУстановка завершена! Перезагрузитесь командой: reboot\033[0m"
