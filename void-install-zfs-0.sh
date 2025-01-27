#!/usr/bin/env bash

source /etc/os-release
export ID=${ID}z

generateHostid(){
# chars must be 0-9, a-f, A-F and exactly 8 chars
local host_id=$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 8 | head -n 1)
a=${host_id:6:2}
b=${host_id:4:2}
c=${host_id:2:2}
d=${host_id:0:2}
echo -ne \\x$a\\x$b\\x$c\\x$d > /etc/hostid
}

DISK="/dev/nvme0n1"

# Wipe partitions
print "Disk preparation"
dd if=/dev/zero of="$DISK" bs=512 count=1
zpool labelclear -f "$DISK"
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

# Partitioning
partitioning () {
    # EFI part
    print "Creating EFI part"
    sgdisk -n1:0:+512M -c 1:EFI -t1:EF00 "$DISK"
    EFI="$DISK-part1"

    # SWAP part
    print "Creating the SWAP part"
    sgdisk -n2:0:+16384M -c 2:SWAP -t2:8200 "$DISK"
    SWAP="$DISK-part2"

    # ZFS part
    print "Creating the ZFS part"
    sgdisk -n3:0:0 -c 3:VOIDZ -t3:BF00 "$DISK"
    VOIDZ="$DISK-part3"

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

partitioning


# ZFS pool creation
print "Creating the zpool"

zpool create -f -o ashift=12 		 \
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
-m none zroot "$VOIDZ


# Create initial file systems
print "Creating initial file systems"

zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/"$ID"
zfs create -o mountpoint=/home zroot/home

zpool set bootfs=zroot/ROOT/"$ID" zroot


# Export, then re-import with a temporary mountpoint of /mnt
zpool export zroot
zpool import -N -R /mnt zroot
zfs mount zroot/ROOT/"$ID"
zfs mount zroot/home


# Verify that everything is mounted correctly
mount | grep mnt

# Update device symlinks
udevadm trigger


# Install Void
print "Installing the system"

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
base-system

# Install packages
print 'Installing packages'

PKGS=(
git bash-completion vim firejail sl base-devel fontconfig-devel xorg-server \
xorg-apps xorg-minimal xinit xterm xcape xset xrdb xwallpaper setxkbmap \
xorg-video-drivers xf86-video-intel xf86-input-libinput libX11-devel \
libXft-devel libXinerama-devel libXft-devel freetype-devel xdg-utils \
intel-ucode ntfs-3g fuse-exfat simple-mtpfs udevil tlp powertop htop \
lm_sensors fzf intel-ucode alsa-utils alsa-plugins alsa-lib alsa-firmware \
smartmontools wget curl urlview bluez acpi_call-dkms bridge-utils zstd zfs \
zfsbootmenu efibootmgr gummiboot refind chrony cronie acpid socklog-void \
dhclient iwd openresolv ansible feh ghostscript zathura-pdf-mupdf redshift picom
)

XBPS_ARCH=$ARCH xbps-install -y -S -r /mnt -R "$REPO" "${PKGS[@]}"

# Set hostname
read -r -p 'Please enter hostname : ' hostname
echo "$hostname" > /mnt/etc/hostname

# Hostid
generateHostid
cp /etc/hostid /mnt/etc

# Configure zfs
print 'Copy ZFS files'
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

# Chroot into the new OS
chroot /mnt/ /bin/bash -e <<EOF 

# Configure DNS
resolvconf -u

# Configure system
cat << EOF >> /etc/rc.conf
KEYMAP="gb"
TIMEZONE="Europe/London"
HARDWARECLOCK="UTC"
EOF

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

### Configure username
print 'Set your username'
read -r -p "Username: " user

# Add user
zfs create zroot/data/home/${user}
useradd -m ${user} -G network,wheel,socklog,video,audio,input
chown -R ${user}:${user} /home/${user}

# Set root passwd
print 'Set root password'
chroot /mnt /bin/passwd

# Set user passwd
print 'Set user password'
xchroot /mnt /bin/passwd "$user"

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


# Configure Dracut to load ZFS support
cat << EOF > /etc/dracut.conf.d/zol.conf
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
EOF


# Install ZFS
zfs set org.zfsbootmenu:commandline="quiet" zroot/ROOT


# Create an fstab entry and mount
cat << EOF >> /etc/fstab
PARTLABEL=EFI /boot/efi defaults  0 0
PARTLABEL=SWAP  swap  swap  rw,noatime,discard  0 0
EOF

mkdir -p /boot/efi
mount /boot/efi

# Install ZFSBootMenu
mkdir -p /boot/efi/EFI/ZBM
curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

# Install refind
refind-install
rm /boot/refind_linux.conf

cat << EOF > /boot/efi/EFI/ZBM/refind_linux.conf
"Boot default"  "quiet loglevel=0 zbm.skip"
"Boot to menu"  "quiet loglevel=0 zbm.show"
EOF

# Exit the chroot, unmount everything
exit
umount -n -R /mnt

# Export the zpool and reboot
zpool export zroot
reboot
