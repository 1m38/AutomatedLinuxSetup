#!/bin/zsh

# ==== parse arguments
local -A opthash
zparseopts -D -M -A opthash -- \
    -help h=-help \
    -hostname: \
    -device: \
    -swap: \
    -boot:

if [[ -n "${opthash[(i)--help]}" ]]; then
    echo "help"
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

# partitions: boot, root and swap(optional)
if [[ -n "${opthash[(i)--swap]}" ]]; then
    SWAP_SIZE_GB=${opthash[--swap]}
else
    vared -p "Swap size at GiB (zero: won't create swap): " -c SWAP_SIZE_GB
fi

if [[ -n "${opthash[(i)--boot]}" ]]; then
    BOOT_PARTITION_TYPE=${opthash[--boot]}
else
    vared -p "/boot partition type (Virtualbox/VMware: EF02, others: EF00): " -c BOOT_PARTITION_TYPE
fi

echo
echo "Hostname: ${NEWHOSTNAME}"
echo "Device for install: /dev/${DEVICE_DISK_INSTALL}"
echo "Swap size: ${SWAP_SIZE_GB}GB"
echo "/boot partition type: ${BOOT_PARTITION_TYPE}"

read "?Continue? [Y/n]" Answer
case $Answer in
    '' | [Yy]* ) ;;
    * )
        exit
        ;;
esac


set -exu

# ==== setup storage
if [[ -z $BOOT_PARTITION_TYPE ]]; then
    # Virtualbox
    PARTITION_BOOT_ID=
    PARTITION_ROOT_ID=1
else
    # VMware or others
    PARTITION_BOOT_ID=1
    PARTITION_ROOT_ID=2
fi
if [[ SWAP_SIZE_GB -gt 0 ]]; then
    PARTITION_SWAP_ID=$(( $PARTITION_ROOT_ID + 1 ))
else
    PARTITION_SWAP_ID=
fi

sgdisk -o /dev/$DEVICE_DISK_INSTALL
# /boot
if [[ -n $PARTITION_BOOT_ID ]]; then
    if [[ $BOOT_PARTITION_TYPE = EF00 ]]; then
	BOOT_PARTITION_SIZE_MB=512
    else
	BOOT_PARTITION_SIZE_MB=2
    fi
    sgdisk -n ${PARTITION_BOOT_ID}::${BOOT_PARTITION_SIZE_MB}M -t ${PARTITION_BOOT_ID}:${BOOT_PARTITION_TYPE} /dev/$DEVICE_DISK_INSTALL
fi

# /root, swap
if [[ SWAP_SIZE_GB -gt 0 ]]; then
    # /dev/xxx2: root, /dev/xxx3: swap
    sgdisk -n ${PARTITION_ROOT_ID}::-${SWAP_SIZE_GB}G -t ${PARTITION_ROOT_ID}:8300 /dev/$DEVICE_DISK_INSTALL
    sgdisk -n ${PARTITION_SWAP_ID}::                  -t ${PARTITION_SWAP_ID}:8200 /dev/$DEVICE_DISK_INSTALL
else
    # /dev/xxx2: root
    sgdisk -n ${PARTITION_ROOT_ID}:: -t ${PARTITION_ROOT_ID}:8300 /dev/$DEVICE_DISK_INSTALL
fi
sgdisk -p /dev/$DEVICE_DISK_INSTALL

PARTITION_ROOT=/dev/${DEVICE_DISK_INSTALL}${PARTITION_ROOT_ID}
mkfs.ext4 $PARTITION_ROOT
mount $PARTITION_ROOT /mnt
if [[ -n $PARTITION_BOOT_ID ]]; then
    PARTITION_BOOT=/dev/${DEVICE_DISK_INSTALL}${PARTITION_BOOT_ID}
    mkfs.vfat -F32 $PARTITION_BOOT
    mkdir -p /mnt/boot
    mount $PARTITION_BOOT /mnt/boot
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
echo "LANG=ja_JP.UTF-8" >> /etc/locale.conf
echo -e 'KEYMAP=jp106\nFONT=Lat2-Terminus16' > /etc/vconsole.conf
systemctl enable dhcpcd.service
echo root:$NEWROOTPASS | chpasswd
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

if [[ -n $PARTITION_BOOT_ID ]]; then
    umount $PARTITION_BOOT
fi
umount $PARTITION_ROOT
