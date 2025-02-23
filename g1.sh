#!/bin/bash
set -e

# Конфигурация
MIRROR="https://mirror.yandex.ru/gentoo-distfiles"
STAGE3_PATH="releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt"

# Проверка root и зависимостей
if [ "$EUID" -ne 0 ]; then
  echo "Запустите скрипт от root!"
  exit 1
fi

for cmd in parted wget tar chroot; do
  if ! command -v $cmd &> /dev/null; then
    echo "Ошибка: $cmd не установлен!"
    exit 1
  fi
done

# Функция подтверждения
confirm() {
  read -p "$1 (Y/n): " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

# Шаг 1: Настройка сети
echo -e "\n\033[1;32m[1/13] Настройка сети\033[0m"
confirm "Настроить проводное подключение (dhcpcd)?" && {
  dhcpcd || {
    echo "Ошибка настройки сети!"
    exit 1
  }
}

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
mkfs.fat -F32 ${DISK}1 || exit 1
mkswap ${DISK}2 || exit 1
swapon ${DISK}2 || exit 1
mkfs.ext4 ${DISK}3 || exit 1

# Шаг 4: Монтирование
echo -e "\n\033[1;32m[4/13] Монтирование\033[0m"
mkdir -p /mnt/gentoo
mount ${DISK}3 /mnt/gentoo || exit 1
mkdir -p /mnt/gentoo/boot/efi
mount ${DISK}1 /mnt/gentoo/boot/efi || exit 1

# Шаг 5: Stage3 (исправленный URL)
echo -e "\n\033[1;32m[5/13] Загрузка Stage3\033[0m"
cd /mnt/gentoo
STAGE3_FULL_URL="${MIRROR}/${STAGE3_PATH}"
LATEST_STAGE3=$(wget -qO- ${STAGE3_FULL_URL} | grep -v ^# | awk '{print $1}' | head -1)
wget "${MIRROR}/releases/amd64/autobuilds/${LATEST_STAGE3}" -O stage3.tar.xz || {
  echo "Ошибка загрузки Stage3!"
  exit 1
}
tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner || {
  echo "Ошибка распаковки Stage3!"
  exit 1
}

# Шаг 6: Копирование настроек сети
echo -e "\n\033[1;32m[6/13] Копирование настроек сети\033[0m"
cp /etc/resolv.conf /mnt/gentoo/etc/ || exit 1
if [ -f /etc/NetworkManager/system-connections ]; then
  mkdir -p /mnt/gentoo/etc/NetworkManager/
  cp -r /etc/NetworkManager/system-connections /mnt/gentoo/etc/NetworkManager/ || exit 1
fi

# Шаг 7: Chroot
echo -e "\n\033[1;32m[7/13] Настройка chroot\033[0m"
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev

# Шаг 8: Настройка системы
echo -e "\n\033[1;32m[8/13] Базовая настройка\033[0m"
chroot /mnt/gentoo /bin/bash <<'EOL'
source /etc/profile
export PS1="(chroot) $PS1"

# Обновление Portage
eselect news read
emerge-webrsync || exit 1

# Профиль Systemd
eselect profile list
read -p "Номер профиля Systemd: " PROFILE_NUM
eselect profile set ${PROFILE_NUM} || exit 1

# Обновление системы
emerge --ask --verbose --update --deep --newuse @world || exit 1
EOL

# Шаг 9: Ядро (исправленная версия)
echo -e "\n\033[1;32m[9/13] Установка ядра\033[0m"
confirm "Установить и скомпилировать ядро?" && {
  chroot /mnt/gentoo /bin/bash <<'EOL'
  emerge sys-kernel/gentoo-sources sys-kernel/linux-firmware || exit 1
  cd /usr/src/linux
  make defconfig || exit 1
  make -j$(nproc) || exit 1
  make modules_install || exit 1
  make install || exit 1
  KERNEL_VERSION=$(ls -t /usr/src/linux-* | head -n1 | sed 's/.*linux-//')
  emerge sys-kernel/dracut || exit 1
  dracut --host-only -k "/boot/initramfs-${KERNEL_VERSION}.img" "${KERNEL_VERSION}" || exit 1
EOL
}

# Шаг 10: Fstab
echo -e "\n\033[1;32m[10/13] Генерация fstab\033[0m"
genfstab -U /mnt/gentoo >> /mnt/gentoo/etc/fstab || exit 1

# Шаг 11: Загрузчик (исправленная версия)
echo -e "\n\033[1;32m[11/13] Установка загрузчика\033[0m"
chroot /mnt/gentoo /bin/bash <<'EOL'
bootctl install || exit 1
KERNEL_VERSION=$(ls -t /boot/vmlinuz-* | head -n1 | sed 's/.*vmlinuz-//')
UUID=$(blkid -s UUID -o value /dev/sda3)
cat <<EOF > /boot/loader/entries/gentoo.conf
title Gentoo Linux
linux /vmlinuz-${KERNEL_VERSION}
initrd /initramfs-${KERNEL_VERSION}.img
options root=UUID=${UUID} rw
EOF
EOL

# Шаг 12: Установка драйверов NVIDIA
echo -e "\n\033[1;32m[12/13] Установка драйверов NVIDIA\033[0m"
confirm "Установить драйверы NVIDIA?" && {
  chroot /mnt/gentoo /bin/bash <<'EOL'
  emerge x11-drivers/nvidia-drivers || exit 1
  echo "nvidia" >> /etc/modules-load.d/nvidia.conf || exit 1
  echo "blacklist nouveau" >> /etc/modprobe.d/blacklist.conf || exit 1
EOL
}

# Шаг 13: Графическое окружение
echo -e "\n\033[1;32m[13/13] Установка bspwm\033[0m"
confirm "Установить графическое окружение?" && {
  chroot /mnt/gentoo /bin/bash <<'EOL'
  emerge xorg-server bspwm sxhkd alacritty lightdm || exit 1
  systemctl enable lightdm || exit 1
EOL
}

echo -e "\n\033[1;32mУстановка завершена! Перезагрузитесь командой: umount -R /mnt/gentoo && reboot\033[0m"
