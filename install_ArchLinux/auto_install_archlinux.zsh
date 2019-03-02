#!/bin/zsh

# ==== parse arguments
local -A opthash
zparseopts -D -M -A opthash -- \
    -help h=-help \
    -hostname: \
    -device: \
    -swap: \
    -machine-type:

if [[ -n "${opthash[(i)--help]}" ]]; then
    cat << EOF
Automatically setup ArchLinux.
Usage: zsh auto_install_archlinux.zsh [--help] [-h] [--hostname HOSTNAME] [--device DEVICE] [--swap SWAP_SIZE_GB] [--machine-type TYPE]

options:
    --help, -h: show this help.
    --hostname HOSTNAME: hostname for the installing ArchLinux
    --device DEVICE: device name install ArchLinux for (e.g: sda -> install for /dev/sda)
    --swap SWAP_SIZE_GB: size of swap partition. If 0, won't create a swap partition.
    --machine-type TYPE: machine type, used for deciding boot partition type.
        0 | Physical: create 0.5GB /boot partition as ESP
        1 | Virtual:     create 2MB partition for boot loader (not mount as /boot)
EOF
    exit
fi

# ==== gather informations
# hostname
if [[ -n "${opthash[(i)--hostname]}" ]]; then
    NEWHOSTNAME=${opthash[--hostname]}
else
    vared -p "Hostname: " -c NEWHOSTNAME
fi

# root password
while :; do
    read -s "?Root password: " NEWROOTPASS
    echo
    read -s "?Confirm root password: " CONFIRM_ROOT_PASS
    echo
    if [[ $NEWROOTPASS = $CONFIRM_ROOT_PASS ]]; then
        break
    else
        echo "Password confirmation failed."
    fi
done

# target storage
if [[ -n "${opthash[(i)--device]}" ]]; then
    DEVICE_DISK_INSTALL=${opthash[--device]}
else
    lsblk
    echo "Partitions will be created (all data on the disk will be deleted)."
    vared -p "Install device (e.g: sda): " -c DEVICE_DISK_INSTALL
fi
# check target storage
if [[ ! -e /dev/${DEVICE_DISK_INSTALL} ]]; then
    echo "device /dev/${DEVICE_DISK_INSTALL} not found. Abort."
    exit 1
fi

# Machine type
# 0/Physical:   create 0.5GB /boot partition as ESP
# 1/Virtual:    create 2MB partition for boot loader (not mount as /boot)
if [[ -n "${opthash[(i)--machine-type]}" ]]; then
    MACHINE_TYPE=${opthash[--machine-type]}
else
    vared -p "Machine type (0:Physical, 1:Virtual): " -c MACHINE_TYPE
fi

case "$MACHINE_TYPE" in
    0 | Physical )
        MACHINE_TYPE=Physical
        ;;
    1 | [vV]irtual )
        MACHINE_TYPE=Virtual
        ;;
    * )
        echo "Unknown machine type '${MACHINE_TYPE}'. Abort."
        exit
        ;;
esac

# swap size
if [[ -n "${opthash[(i)--swap]}" ]]; then
    SWAP_SIZE_GB=${opthash[--swap]}
else
    vared -p "Swap size at GiB (zero: won't create swap): " -c SWAP_SIZE_GB
fi

echo
echo "Hostname: ${NEWHOSTNAME}"
echo "Device for install: /dev/${DEVICE_DISK_INSTALL}"
echo "Swap size: ${SWAP_SIZE_GB}GB"
echo "Machine type: ${MACHINE_TYPE}"

read "?Continue? [Y/n]" Answer
case $Answer in
    '' | [Yy]* ) ;;
    * )
        exit
        ;;
esac


set -exu

# ==== setup storage
case "$MACHINE_TYPE" in
    Physical )
        PARTITION_BOOT_ID=1
        PARTITION_ROOT_ID=2
        BOOT_PARTITION_TYPE=EF00
        BOOT_PARTITION_SIZE_MB=512
        ;;
    Virtual )
        PARTITION_BOOT_ID=1
        PARTITION_ROOT_ID=2
        BOOT_PARTITION_TYPE=EF02
        BOOT_PARTITION_SIZE_MB=2
        ;;
    * )
        echo "Unknown machine type '${MACHINE_TYPE}'. Abort."
        exit
        ;;
esac


if [[ SWAP_SIZE_GB -gt 0 ]]; then
    PARTITION_SWAP_ID=$(( $PARTITION_ROOT_ID + 1 ))
else
    PARTITION_SWAP_ID=
fi

sgdisk -o /dev/$DEVICE_DISK_INSTALL
# /boot
if [[ -n $PARTITION_BOOT_ID ]]; then
    sgdisk -n ${PARTITION_BOOT_ID}::${BOOT_PARTITION_SIZE_MB}M -t ${PARTITION_BOOT_ID}:${BOOT_PARTITION_TYPE} /dev/$DEVICE_DISK_INSTALL
fi

# /root, swap
if [[ SWAP_SIZE_GB -gt 0 ]]; then
    sgdisk -n ${PARTITION_ROOT_ID}::-${SWAP_SIZE_GB}G -t ${PARTITION_ROOT_ID}:8300 /dev/$DEVICE_DISK_INSTALL
    sgdisk -n ${PARTITION_SWAP_ID}::                  -t ${PARTITION_SWAP_ID}:8200 /dev/$DEVICE_DISK_INSTALL
else
    sgdisk -n ${PARTITION_ROOT_ID}:: -t ${PARTITION_ROOT_ID}:8300 /dev/$DEVICE_DISK_INSTALL
fi
sgdisk -p /dev/$DEVICE_DISK_INSTALL

# make filesystem, mount
PARTITION_ROOT=/dev/${DEVICE_DISK_INSTALL}${PARTITION_ROOT_ID}
mkfs.ext4 $PARTITION_ROOT
mount $PARTITION_ROOT /mnt
if [[ -n $PARTITION_BOOT_ID ]]; then
    PARTITION_BOOT=/dev/${DEVICE_DISK_INSTALL}${PARTITION_BOOT_ID}
    mkfs.vfat -F32 $PARTITION_BOOT
    if [[ $BOOT_PARTITION_TYPE = EF00 ]]; then
        # EF00 (ESP) -> mount as /boot
        mkdir -p /mnt/boot
        mount $PARTITION_BOOT /mnt/boot
    fi
fi
if [[ -n $PARTITION_SWAP_ID ]]; then
    PARTITION_SWAP=/dev/${DEVICE_DISK_INSTALL}${PARTITION_SWAP_ID}
    mkswap $PARTITION_SWAP
    swapon $PARTITION_SWAP
fi


# ==== Install base system
# change mirrirlist
mv /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.old
grep .jp /etc/pacman.d/mirrorlist.old | grep -v jaist > /etc/pacman.d/mirrorlist
cat /etc/pacman.d/mirrorlist.old >> /etc/pacman.d/mirrorlist
# install
pacstrap /mnt base base-devel

# ==== setting
genfstab -p /mnt >> /mnt/etc/fstab
echo $NEWHOSTNAME > /mnt/etc/hostname

# ==== create a script run on chroot environment
mkdir -p /mnt/root
CHROOT_SETUP_SCRIPT=/root/chroot-setup.sh

cat << EOF > /mnt/$CHROOT_SETUP_SCRIPT
#!/bin/bash
set -exu

ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
pacman -S --noconfirm grub vim net-tools openssh os-prober efibootmgr
echo -e "en_US.UTF-8 UTF-8\nja_JP.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" >> /etc/locale.conf
echo -e 'KEYMAP=jp106\nFONT=Lat2-Terminus16' > /etc/vconsole.conf
systemctl enable dhcpcd.service
echo "root:${NEWROOTPASS}" | chpasswd
EOF


if [[ $BOOT_PARTITION_TYPE = EF00 ]]; then
    # UEFI/grub
    cat << EOF >> /mnt/$CHROOT_SETUP_SCRIPT
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub
grub-mkconfig -o /boot/grub/grub.cfg
EOF
else
    # BIOS/grub
    cat << EOF >> /mnt/$CHROOT_SETUP_SCRIPT
grub-install --recheck /dev/$DEVICE_DISK_INSTALL
grub-mkconfig -o /boot/grub/grub.cfg
EOF

fi


chmod +x /mnt$CHROOT_SETUP_SCRIPT
arch-chroot /mnt $CHROOT_SETUP_SCRIPT

if [[ $BOOT_PARTITION_TYPE = EF00 ]]; then
    umount $PARTITION_BOOT
fi
umount $PARTITION_ROOT
reboot