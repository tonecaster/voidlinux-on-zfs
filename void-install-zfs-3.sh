#!/usr/bin/env bash

source /etc/os-release
export ID=${ID}z

# Generate zfs hostid
generateHostid(){
# chars must be 0-9, a-f, A-F and exactly 8 chars
local host_id=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 8 | head -n 1)
a=${host_id:6:2}
b=${host_id:4:2}
c=${host_id:2:2}
d=${host_id:0:2}
echo -ne \\x$a\\x$b\\x$c\\x$d > /etc/hostid
}

set -e
exec &> >(tee "configure.log")

print () {
    echo -e "\n\033[1m> $1\033[0m\n"
}

ask () {
    read -p "> $1 " -r
    echo
}

menu () {
    PS3="> Choose a number: "
    select i in "$@"
    do
        echo "$i"
        break
    done
}

# Tests
tests () {
    ls /sys/firmware/efi/efivars > /dev/null && \
        ping voidlinux.org -c 1 > /dev/null &&  \
        modprobe zfs &&                         \
        print "Tests ok"
}

select_disk () {
    # Set DISK
    select ENTRY in $(ls /dev/disk/by-id/);
    do
        DISK="/dev/disk/by-id/$ENTRY"
        echo "$DISK" > /tmp/disk
        echo "Installing on $ENTRY."
        break
    done
}

wipe () {
    ask "Do you want to wipe all datas on $ENTRY ?"
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        # Clear disk
        dd if=/dev/zero of="$DISK" bs=512 count=1
        zpool labelclear -f "$DISK"
        sgdisk --zap-all "$DISK"
        wipefs -af "$DISK"
        sgdisk -Zo "$DISK"
    fi
}

partition () {
    # EFI part
    print "Creating EFI part"
    sgdisk -n1:0:+512M -c 1:"EFI" -t1:EF00 "$DISK"
    EFI="$DISK-part1"

    # SWAP part
    print "Creating the SWAP part"
    sgdisk -n2:0:+16384M -c 2:"SWAP" -t2:8200 "$DISK"
    SWAP="$DISK-part2"

    # ZFS part
    print "Creating the ZFS part"
    sgdisk -n3:0:0 -c 3:"POOL" -t3:BF00 "$DISK"
    ZFS="$DISK-part3"

    # Inform kernel
    partprobe "$DISK"

    # Format efi part
    sleep 1
    print "Format EFI part"
    mkfs.vfat -F32 "$EFI"
    
    # Format swap part
    sleep 1
    print "Format SWAP part"
    mkswap "$SWAP"
}

create_pool () {
        
    # Create ZFS pool
    print "Create ZFS pool"
    zpool create -f -o ashift=12                          \
                 -o autotrim=on                           \
                 -O acltype=posixacl                      \
                 -O compression=lz4                       \
                 -O relatime=on                           \
                 -O xattr=sa                              \
                 -O dnodesize=auto                        \
                 -O normalization=formD                   \
                 -O mountpoint=none                       \
                 -O canmount=off                          \
                 -O devices=off                           \
                 -R /mnt                                  \
                 zroot "$ZFS"
}

create_root_dataset () {
    # Slash dataset
    print "Create root dataset"
    zfs create -o mountpoint=none zroot/ROOT

    # Set cmdline
    zfs set org.zfsbootmenu:commandline="ro quiet" zroot/ROOT
}

create_system_dataset () {
    print "Create slash dataset"
    zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/"$ID"

    # Generate zfs hostid
    print "Generate hostid"
    generateHostid

    # Set bootfs
    print "Set ZFS bootfs"
    zpool set bootfs="zroot/ROOT/$ID" zroot

    # Manually mount slash dataset
    zfs mount zroot/ROOT/"$ID"
}

create_home_dataset () {
    print "Create home dataset"
    zfs create -o mountpoint=/ -o canmount=off zroot/data
    zfs create -o mountpoint=/home zroot/data/home
    zfs create -o mountpoint=/root zroot/data/home/root
}

export_pool () {
    print "Export zpool"
    zpool export zroot
}

import_pool () {
    print "Import zpool"
    zpool import -d /dev/disk/by-id -R /mnt zroot -N -f
}

mount_system () {
    print "Mount slash dataset"
    zfs mount zroot/ROOT/"$ID"
    zfs mount -a

    # Mount EFI part
    print "Mount EFI part"
    EFI="$DISK-part1"
    mkdir -p /mnt/efi
    mount "$EFI" /mnt/efi
}

copy_zpool_cache () {
    # Copy ZFS cache
    print "Generate and copy zfs cache"
    mkdir -p /mnt/etc/zfs
    zpool set cachefile=/etc/zfs/zpool.cache zroot
}

# Main

tests

print "Is this the first install or a second install to dualboot ?"
install_reply=$(menu first dualboot)

select_disk

# If first install
if [[ $install_reply == "first" ]]
then
    # Wipe the disk
    wipe
    # Create partition table
    partition
    # Create ZFS pool
    create_pool
    # Create root dataset
    create_root_dataset
fi

ask "Name of the slash dataset ?"
name_reply="$REPLY"
echo "$name_reply" > /tmp/root_dataset

if [[ $install_reply == "dualboot" ]]
then
    import_pool
fi

create_system_dataset "$name_reply"

if [[ $install_reply == "first" ]]
then
    create_home_dataset
fi

export_pool
import_pool
mount_system "$name_reply"
copy_zpool_cache

# Finish
echo -e "\e[32mAll OK"

sleep 1
echo -e "Now to the install part..."
sleep 1

set -e
exec &> >(tee "install.log")

# Debug
if [[ "$1" == "debug" ]]
then
    set -x
    debug=1
fi

print () {
    echo -e "\n\033[1m> $1\033[0m\n"
    if [[ -n "$debug" ]]
    then
      read -rp "press enter to continue"
    fi
}

# Root dataset
root_dataset=$(cat /tmp/root_dataset)

# Set mirror and architecture
REPO=https://repo-default.voidlinux.org/current/musl
ARCH=x86_64-musl

# Copy keys
print 'Copy xbps keys'
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

### Install base system
print 'Install Void Linux'
XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" \
  void-repo-nonfree \
  base-system \

# Init chroot
print 'Init chroot'
mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys
mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev
mount --rbind /proc /mnt/proc && mount --make-rslave /mnt/proc

# Disable gummiboot post install hooks, only installs for generate-zbm
echo "GUMMIBOOT_DISABLE=1" > /mnt/etc/default/gummiboot

# Install packages
print 'Install packages'

PKGS=(
git 
bash-completion 
vim 
firejail 
sl 
xorg-server 
xorg-apps 
xorg-minimal 
xinit 
xterm 
xcape 
xset
xrdb
xwallpaper
setxkbmap
xorg-video-drivers 
xf86-video-intel 
xf86-input-libinput 
libX11-devel 
libXft-devel 
libXinerama-devel 
libXft-devel 
freetype-devel 
xdg-utils 
setxkbmap 
intel-ucode
ntfs-3g 
fuse-exfat 
simple-mtpfs 
udevil
tlp 
powertop 
htop 
lm_sensors 
fzf 
intel-ucode 
alsa-utils 
alsa-plugins 
alsa-lib 
alsa-firmware 
smartmontools 
wget 
curl 
urlview 
base-devel 
fontconfig-devel 
bluez 
acpi_call-dkms 
bridge-utils 
zstd 
zfs
zfsbootmenu 
efibootmgr 
gummiboot 
refind
chrony 
cronie 
acpid 
socklog-void 
iwd 
dhclient 
openresolv 
ansible
feh
ghostscript
zathura-pdf-mupdf
redshift
picom
)

XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" "${PKGS[@]}"

# Set hostname
read -r -p 'Please enter hostname : ' hostname
echo "$hostname" > /mnt/etc/hostname

# Configure zfs
print 'Copy ZFS files'
cp /etc/hostid /mnt/etc/hostid
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

# Configure iwd
cat > /mnt/etc/iwd/main.conf <<"EOF"
[General]
UseDefaultInterface=true
EnableNetworkConfiguration=true
EOF

# Copy wpa_supplicant
mkdir -p /mnt/etc/wpa_supplicant
cp /etc/wpa_supplicant/wpa_supplicant.conf /mnt/etc/wpa_supplicant/wpa_supplicant.conf

# Configure DNS
cat >> /mnt/etc/resolvconf.conf <<"EOF"
resolv_conf=/etc/resolv.conf
name_servers_append="1.1.1.1 9.9.9.9"
name_server_blacklist="192.168.*"
EOF

# Enable ip forward
cat > /mnt/etc/sysctl.conf <<"EOF"
net.ipv4.ip_forward = 1
EOF

# Prepare locales and keymap
print 'Prepare locales and keymap'
echo 'KEYMAP=uk' > /mnt/etc/vconsole.conf
echo 'en_GB.UTF-8 UTF-8' > /mnt/etc/default/libc-locales
echo 'LANG="en_GB.UTF-8"' > /mnt/etc/locale.conf

# Configure system
cat >> /mnt/etc/rc.conf << EOF
KEYMAP="gb"
TIMEZONE="Europe/London"
HARDWARECLOCK="UTC"
EOF

# Configure dracut
print 'Configure dracut'
cat > /mnt/etc/dracut.conf.d/zol.conf <<"EOF"
hostonly="yes"
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs resume "
EOF

### Configure username
print 'Set your username'
read -r -p "Username: " user

### Chroot
print 'Chroot to configure services'
chroot /mnt/ /bin/bash -e <<EOF 
# Configure DNS
resolvconf -u

# Configure services
#ln -s /etc/sv/dhcpcd-eth0 /etc/runit/runsvdir/default/
ln -s /etc/sv/dhcpcd /etc/runit/runsvdir/default/
ln -s /etc/sv/wpa_supplicant /etc/runit/runsvdir/default/ 
#ln -s /etc/sv/iwd /etc/runit/runsvdir/default/
ln -s /etc/sv/chronyd /etc/runit/runsvdir/default/
ln -s /etc/sv/crond /etc/runit/runsvdir/default/
ln -s /etc/sv/dbus /etc/runit/runsvdir/default/
#ln -s /etc/sv/seatd /etc/runit/runsvdir/default/
ln -s /etc/sv/acpid /etc/runit/runsvdir/default/
ln -s /etc/sv/socklog-unix /etc/runit/runsvdir/default/
ln -s /etc/sv/nanoklogd /etc/runit/runsvdir/default/

# Add user
zfs create zroot/data/home/${user}
useradd -m ${user} -G network,wheel,socklog,video,audio,input
chown -R ${user}:${user} /home/${user}

# Configure fstab
grep efi /proc/mounts > /etc/fstab
EOF

# Configure fstab
print 'Configure fstab'
cat >> /mnt/etc/fstab <<"EOF"
tmpfs  /dev/shm  tmpfs  rw,nosuid,nodev,noexec,inode64  0 0
tmpfs  /tmp  tmpfs  defaults,nosuid,nodev  0 0
efivarfs  /sys/firmware/efi/efivars  efivarfs  defaults  0 0
PARTLABEL=SWAP  swap  swap  rw,noatime,discard  0 0      
EOF

#echo "/dev/disk/by-id/$(ls /dev/disk/by-id | grep 35-part2)   swap    swap   rw,noatime,discard  0 0" >> /mnt/etc/fstab

# Set root passwd
print 'Set root password'
chroot /mnt /bin/passwd

# Set user passwd
print 'Set user password'
chroot /mnt /bin/passwd "$user"

# Configure sudo
print 'Configure sudo'
cat > /mnt/etc/sudoers <<EOF
root ALL=(ALL) ALL
$user ALL=(ALL) NOPASSWD:ALL
Defaults rootpw
EOF

# Turn off that annoying console bell
echo "blacklist pcspkr" > /mnt/etc/modprobe.d/blacklist.conf

# Create default directories within home
mkdir /mnt/home/${user}/.config
mkdir /mnt/home/${user}/Documents
mkdir /mnt/home/${user}/Downloads
mkdir -p /mnt/home/${user}/Pictures/Backgrounds
mkdir /mnt/home/${user}/Videos

### Configure zfsbootmenu

# Create dirs
mkdir -p /mnt/efi/EFI/ZBM /etc/zfsbootmenu/dracut.conf.d

# Generate zfsbootmenu efi
print 'Configure zfsbootmenu'
cat > /mnt/etc/zfsbootmenu/config.yaml <<EOF
Global:
  ManageImages: true
  BootMountPoint: /efi
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
Components:
  Enabled: false
EFI:
  ImageDir: /efi/EFI/ZBM
  Versions: false
  Enabled: true
Kernel:
  CommandLine: ro quiet loglevel=0
  Prefix: vmlinuz
EOF

# Add keymap to dracut
cat > /mnt/etc/zfsbootmenu/dracut.conf.d/keymap.conf <<EOF
install_optional_items+=" /etc/cmdline.d/keymap.conf "
EOF

mkdir -p /mnt/etc/cmdline.d/
cat > /mnt/etc/cmdline.d/keymap.conf <<EOF
rd.vconsole.keymap=uk
EOF

# Set cmdline
zfs set org.zfsbootmenu:commandline="ro quiet nowatchdog" zroot/ROOT/"$root_dataset"

# Generate ZBM
print 'Generate zbm'
chroot /mnt/ /bin/bash -e <<"EOF"
  # Export locale
  export LANG="en_GB.UTF-8"
  # Generate initramfs, zfsbootmenu
  xbps-reconfigure -fa
EOF

# Set DISK
if [[ -f /tmp/disk ]]
then
  DISK=$(cat /tmp/disk)
else
  print 'Select the disk you installed on:'
  select ENTRY in $(ls /dev/disk/by-id/);
  do
      DISK="/dev/disk/by-id/$ENTRY"
      echo "Creating boot entries on $ENTRY."
      break
  done
fi

# Create UEFI entries
#print 'Create efi boot entries'
#modprobe efivarfs
#mountpoint -q /sys/firmware/efi/efivars \
#    || mount -t efivarfs efivarfs /sys/firmware/efi/efivars

#if efibootmgr | grep ZFSBootMenu
#then
#  for entry in $(efibootmgr | grep ZFSBootMenu | sed -E 's/Boot([0-9]+).*/\1/')
#  do
#    efibootmgr -B -b "$entry"
#  done
#fi
#efibootmgr --disk "$DISK" \
#  --part 1 \
#  --create \
#  --label "ZFSBootMenu Backup" \
#  --loader "\EFI\ZBM\vmlinuz-backup.efi" \
#  --verbose
#efibootmgr --disk "$DISK" \
#  --part 1 \
#  --create \
#  --label "ZFSBootMenu" \
#  --loader "\EFI\ZBM\vmlinuz.efi" \
#  --verbose

/mnt/usr/bin/refind-install
rm /boot/refind_linux.conf
cat << EOF > /boot/efi/EFI/ZBM/refind_linux.conf
"Boot default"  "quiet loglevel=0 zbm.skip"
"Boot to menu"  "quiet loglevel=0 zbm.show"
EOF

# Umount all parts
print 'Umount all parts'
umount /mnt/efi
umount -l /mnt/{dev,proc,sys}
zfs umount -a

# Export zpool
print 'Export zpool'
zpool export zroot

# Finish
echo -e '\e[32mAll OK\033[0m'
