#!/bin/bash

export TARGET_DEVICE=""
export LUKS_PASSPHRASE=""
export ROOT_PASSPHRASE=""

export LUKS_DEV_NAME="root"
export PKGS="xtools vsv vpm ansible python3 cryptsetup curl wget git jq grub-btrfs grub-btrfs-runit snapper"
export PKGS="$PKGS socklog-void cronie libnfs nfs-utils dbus elogind wireguard-tools tailscale xmirror"

export GRUB_PKG="grub"

# if efi vars are present export correct grub
test -d "/sys/firmware/efi/efivars" && export GRUB_PKG="grub-x86_64-efi"

xi -Sy jq

function blkq() {
  lsblk -b "$TARGET_DEVICE" --json | jq ".blockdevices[] | select(.name == \"$(basename $TARGET_DEVICE)\")"
}

bios_dev="${TARGET_DEVICE}1"
esp_dev="${TARGET_DEVICE}2"
root_dev="${TARGET_DEVICE}3"
real_root_dev="/dev/mapper/rootfs"

sv_opts="rw,noatime,compress-force=zstd:1,space_cache=v2"

create_subvolumes=$(cat <<EOF
{
  "@var": "/var",
  "@tmp": "/var/tmp",
  "@log": "/var/log",
  "@home": "/home",
  "@cache": "/var/cache",
  "@docker": "/var/lib/docker",
  "@libvirt": "/var/lib/libvirt"
}
EOF
)


# unmount any filesystems mounted onto the /mnt
#mountpoint -q /mnt || umount -R /mnt
umount -R /mnt

# check if old luks partiton is opened
test -b "${real_root_dev}" && cryptsetup luksClose "$(basename $real_root_dev)"
wipefs -f -a "${TARGET_DEVICE}"

sector_size=512

sfdisk "$TARGET_DEVICE" <<EOF
label: gpt
device: ${TARGET_DEVICE}
unit: sectors
sector-size: $sector_size

$bios_dev : start=    2048, size=     2048,   type=21686148-6449-6E6F-744E-656564454649
$esp_dev : start=    4096, size=     524288, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
$root_dev : start=    528384, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF

# Destroy any existing luks headers
dd if=/dev/urandom of=/tmp/key.bin bs=512 count=1

cryptsetup luksFormat $root_dev --type luks1 --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id --key-file /tmp/key.bin
cryptsetup luksOpen $root_dev "$(basename $real_root_dev)" --key-file /tmp/key.bin
echo -n "$LUKS_PASSPHRASE" | cryptsetup luksAddKey $root_dev --key-file /tmp/key.bin

mkfs.vfat -F32 ${esp_dev}
mkfs.btrfs -f -L B_ROOT ${real_root_dev}

mount -t btrfs -o $sv_opts ${real_root_dev} /mnt

btrfs subvolume create /mnt/@

echo "$create_subvolumes" > /tmp/subvols.json
jq -r 'to_entries | .[] | "\(.key) \(.value)"' "/tmp/subvols.json" | while read -r k v; do
    echo "creating subvolume $k"
    btrfs subvolume create "/mnt/${k}"
done

umount -R /mnt

mount -t btrfs -o ${sv_opts},subvol=@ $real_root_dev /mnt || exit 1

jq -r 'to_entries | .[] | "\(.key) \(.value)"' "/tmp/subvols.json" | while read -r k v; do
  echo "mkdir: $k => /mnt$v"
  mkdir -p "/mnt$v"
  echo "mount: $k => /mnt$v"
  mount -t btrfs -o ${sv_opts},subvol=$k $real_root_dev /mnt$v || exit 1
done

mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
xbps-install -Sy -R https://repo-default.voidlinux.org/current -r /mnt  base-system ${PKGS} $GRUB_PKG

root_dev_uuid="$(blkid -o value -s UUID $root_dev)"
real_root_uuid="$(blkid -o value -s UUID ${real_root_dev})"
esp_uuid="$(blkid -o value -s UUID ${esp_dev})"

cat <<EOF > /mnt/etc/fstab
UUID=${esp_uuid} /.esp vfat  defaults   0   0
$(
  jq -r 'to_entries | .[] | "\(.key) \(.value)"' "/tmp/subvols.json" | while read -r k v; do
    echo "UUID=${real_root_uuid} $v btrfs ${sv_opts},subvol=$k   0   0"
  done
)
EOF
echo -e "$(basename ${real_root_dev})    UUID=${root_dev_uuid}  /.key.bin     luks\n" > /mnt/etc/crypttab
cp /tmp/key.bin /mnt/.key.bin
mkdir -p /mnt/etc/dracut.conf.d
echo -e "install_items+=\" /.key.bin /etc/crypttab \"\n" > /mnt/etc/dracut.conf.d/10-crypt.conf

cat <<EOF > /mnt/etc/default/grub
#
# Configuration file for GRUB.
#
GRUB_DEFAULT=0
#GRUB_HIDDEN_TIMEOUT=0
#GRUB_HIDDEN_TIMEOUT_QUIET=false
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Void"
GRUB_ENABLE_CRYPTODISK=y
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rd.luks=1 rd.luks.key=/.key.bin rd.luks.uuid=$root_dev_uuid net.ifnames=0"
# Uncomment to use basic console
#GRUB_TERMINAL_INPUT="console"
# Uncomment to disable graphical terminal
#GRUB_TERMINAL_OUTPUT=console
#GRUB_BACKGROUND=/usr/share/void-artwork/splash.png
#GRUB_GFXMODE=1920x1080x32
#GRUB_DISABLE_LINUX_UUID=true
#GRUB_DISABLE_RECOVERY=true
# Uncomment and set to the desired menu colors.  Used by normal and wallpaper
# modes only.  Entries specified as foreground/background.
#GRUB_COLOR_NORMAL="light-blue/black"
#GRUB_COLOR_HIGHLIGHT="light-cyan/blue"

EOF


cat <<EOF > /mnt/etc/default/grub-btrfs/config
#!/usr/bin/env bash


GRUB_BTRFS_VERSION=4.12-master-2023-04-28T16:26:00+00:00

# Disable grub-btrfs.
# Default: "false"
#GRUB_BTRFS_DISABLE="true"
GRUB_BTRFS_SUBMENUNAME="Void Linux snapshots"

#GRUB_BTRFS_TITLE_FORMAT=("date" "snapshot" "type" "description")

#GRUB_BTRFS_SUBVOLUME_SORT="+ogen,-gen,path,rootid"

# Show snapshots found during run "grub-mkconfig"
# Default: "true"
GRUB_BTRFS_SHOW_SNAPSHOTS_FOUND="true"

# Show Total of snapshots found during run "grub-mkconfig"
# Default: "true"
GRUB_BTRFS_SHOW_TOTAL_SNAPSHOTS_FOUND="true"


GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS="rd.live.overlay.overlayfs=1"

# Comma seperated mount options to be used when booting a snapshot.
#GRUB_BTRFS_ROOTFLAGS="space_cache,commit=10,norecovery"

# Ignore specific path during run "grub-mkconfig".
GRUB_BTRFS_IGNORE_SPECIFIC_PATH=("@")

# Ignore prefix path during run "grub-mkconfig".
# Any path starting with the specified string will be ignored.
# Default: ("var/lib/docker" "@var/lib/docker" "@/var/lib/docker")
#GRUB_BTRFS_IGNORE_PREFIX_PATH=("var/lib/docker" "@var/lib/docker" "@/var/lib/docker")

# Ignore specific type/tag of snapshot during run "grub-mkconfig".
# For snapper:
# Type = single, pre, post.
# For Timeshift:
# Tag = boot, ondemand, hourly, daily, weekly, monthly.
# Default: ("")
#GRUB_BTRFS_IGNORE_SNAPSHOT_TYPE=("")

#GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION="true"

# Location of the folder containing the "grub.cfg" file.
# Might be grub2 on some systems.
# Default: "/boot/grub"
GRUB_BTRFS_GRUB_DIRNAME="/.esp/grub"

# Location of kernels/initramfs/microcode.
# Use by "grub-btrfs" to detect the boot partition and the location of kernels/initrafms/microcodes.
# Default: "/boot"
GRUB_BTRFS_BOOT_DIRNAME="/boot"

# Location where grub-btrfs.cfg should be saved.
# Some distributions (like OpenSuSE) store those files at the snapshot directory
# instead of boot. Be aware that this direcory must be available for grub during
# startup of the system.
# Default: $GRUB_BTRFS_GRUB_DIRNAME
GRUB_BTRFS_GBTRFS_DIRNAME="/.esp/grub"

# Location of the directory where Grub searches for the grub-btrfs.cfg file.
# Some distributions (like OpenSuSE) store those file at the snapshot directory
# instead of boot. Be aware that this direcory must be available for grub during
# startup of the system.
# Default: "\${prefix}" # This is a grub variable that resolves to where grub is
# installed. (like /boot/grub, /boot/efi/grub)
# NOTE: If variables of grub are used here (like ${prefix}) they need to be escaped
#GRUB_BTRFS_GBTRFS_SEARCH_DIRNAME="\${prefix}"



#GRUB_BTRFS_PROTECTION_AUTHORIZED_USERS="root"
#
# Disable authentication support for submenu of Grub-btrfs only (--unrestricted)
# doesn't work if GRUB_BTRFS_PROTECTION_AUTHORIZED_USERS isn't empty
# Default: "false"
#GRUB_BTRFS_DISABLE_PROTECTION_SUBMENU="true"

EOF


cat <<EOF > /mnt/bin/post-install.sh
#!/bin/bash
chown root:root /
chmod 755 /
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
grub-install --efi-directory=/.esp --bootloader-id=Void --boot-directory=/.esp  $TARGET_DEVICE
grub-mkconfig -o /.esp/grub/grub.cfg
xbps-reconfigure -fa
EOF

passwd --root /mnt <<EOF
$ROOT_PASSPHRASE
$ROOT_PASSPHRASE
EOF
exit 1;
chmod +x /mnt/bin/post-install.sh
xchroot /mnt /bin/post-install.sh
rm -rf /bin/post-install.sh