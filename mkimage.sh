#!/bin/sh

MIRROR=http://mirrordirector.raspbian.org/raspbian/
HOSTNAME=machinekit
ROOT=rootfs
IMAGE=rpi-machinekit-1.0.img
TARBALL=rpi_debs.tgz
DEBOOTSTRAP_ARGS="--no-check-gpg --include=keyboard-configuration,ca-certificates wheezy"

if [ `whoami` != 'root' ]
then
    echo "This script needs root privileges to work"
    exit 1
fi

# start clean
rm -rf ${ROOT}

# check if tarball exists
if [ ! -e `pwd`/${TARBALL} ]
then
    echo "creating tarball..."
    debootstrap --make-tarball=`pwd`/${TARBALL} ${DEBOOTSTRAP_ARGS} ${ROOT} ${MIRROR} \
        || exit $?
    echo "...done"
fi

echo "running debootstrap..."
debootstrap --unpack-tarball=`pwd`/${TARBALL} ${DEBOOTSTRAP_ARGS} ${ROOT} ${MIRROR} \
    || exit $?
echo "...done"

#edit hostname
echo ${HOSTNAME} > ${ROOT}/etc/hostname
echo '127.0.0.1\t'${HOSTNAME} >> ${ROOT}/etc/hosts

# edit network interface
cat << EOF > ${ROOT}/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# edit fstab
cat << EOF > ${ROOT}/etc/fstab
proc /proc proc defaults 0 0
/dev/mmcblk0p1 /boot vfat defaults 0 0
EOF

# create /etc/resolv.conf
cp /etc/resolv.conf ${ROOT}/etc

# update apt sources
sed -i 's/main/main firmware/g' ${ROOT}/etc/apt/sources.list
echo 'deb http://0ptr.link/raspbian wheezy main' > \
    ${ROOT}/etc/apt/sources.list.d/rpi-machinekit.list

# copy cache
if [ -d archives ]
then
    rsync -a archives ${ROOT}/var/cache/apt/
fi

# commands need to run under chroot

cat <<EOF_CMD > ${ROOT}/tmp/run.sh
#!/bin/sh

# disable daemon startup
RUNLEVEL=1

# add public key
apt-key adv --keyserver hkp://keys.gnupg.net --recv-key 49550439
apt-get update

apt-get -y upgrade

# install RPi specific
apt-get -y install libraspberrypi-bin libraspberrypi0 fake-hwclock\
    raspberrypi-bootloader-nokernel

# install kernel
apt-get -y install linux-image-xenomai

# install machinekit
apt-get -y install machinekit-xenomai

# extra packages
apt-get -y install --no-install-recommends locales sudo openssh-server \
    ntp usbmount rsync

# minimal X
apt-get -y install --no-install-recommends xinit xserver-xorg-core \
    xserver-xorg xserver-xorg-input-all xserver-xorg-input-evdev \
    xserver-xorg-video-fbdev

# minimal window manager
apt-get -y install --no-install-recommends lxde lxde-icon-theme iceweasel

# Enable remote desktop access
apt-get -y install xrdp

# add user pi
adduser --disabled-password --gecos "pi" pi
usermod -a -G xenomai,sudo,staff,kmem,plugdev,adm,dialout,cdrom,audio,video,games,users pi

# set password
echo -n pi:raspberry | chpasswd

# configure usbmount
sed -i -e 's/""/"-fstype=vfat,flush,gid=plugdev,dmask=0007,fmask=0117"/g' \
    /etc/usbmount/usbmount.conf

# configure udev rules
cat <<EOF >/etc/udev/rules.d/xenomai.rules
# allow RW access to /dev/mem
KERNEL=="mem", MODE="0660", GROUP="kmem" 
# real-time heap device (Xenomai:rtheap)
KERNEL=="rtheap", MODE="0660", GROUP=="xenomai"
# real-time pipe devices (Xenomai:rtpipe)
KERNEL=="rtp[0-9]*", MODE="0660", GROUP="xenomai"
EOF

# done
exit
EOF_CMD

chmod +x ${ROOT}/tmp/run.sh

LC_ALL=C LANGUAGE=C LANG=C chroot ${ROOT} /tmp/run.sh

rm ${ROOT}/tmp/run.sh

# update sudoers
sed -i "s/%sudo\tALL=(ALL:ALL)/%sudo\tALL=NOPASSWD:/g"  \
    ${ROOT}/etc/sudoers

# there is no hw clock on rpi
echo "HWCLOCKACCESS=no" >> ${ROOT}/etc/default/hwclock

# fix ssh keys
rm -f ${ROOT}/etc/ssh/ssh_host_*
cat << EOF > ${ROOT}/etc/init.d/ssh_gen_host_keys
#!/bin/sh
### BEGIN INIT INFO
# Provides:          Generates new ssh host keys on first boot
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: Generates new ssh host keys on first boot
# Description:       Generates new ssh host keys on first boot
### END INIT INFO
ssh-keygen -f /etc/ssh/ssh_host_rsa_key -t rsa -N ""
ssh-keygen -f /etc/ssh/ssh_host_dsa_key -t dsa -N ""
insserv -r /etc/init.d/ssh_gen_host_keys
rm -f \$0
EOF
chmod a+x ${ROOT}/etc/init.d/ssh_gen_host_keys
LC_ALL=C LANGUAGE=C LANG=C chroot ${ROOT} insserv /etc/init.d/ssh_gen_host_keys

# backup cache
rsync -a ${ROOT}/var/cache/apt/archives .

# cleanup
rm -f ${ROOT}/var/lib/apt/lists/*
LC_ALL=C LANGUAGE=C LANG=C chroot ${ROOT} apt-get clean
rm -f ${ROOT}/etc/resolv.conf

# copy kernel
cp ${ROOT}/boot/vmlinuz* ${ROOT}/boot/kernel.img

# create sparse file
rm -f {IMAGE}
dd if=/dev/zero of=${IMAGE} count=0 bs=1 seek=2021654528

# create partitions
cat <<EOF | sfdisk --force ${IMAGE}
unit: sectors

1 : start=     2048, size=   204800, Id= c
2 : start=   206848, size=  3741696, Id=83
EOF

# format partitions
echo "formatting partitions..."
losetup /dev/loop7 ${IMAGE} -o $((2048*512)) || exit $?
mkfs.vfat -F 32 -n BOOT /dev/loop7 || exit $?
losetup -d /dev/loop7 || exit $?
losetup /dev/loop7 ${IMAGE} -o $((206848*512)) || exit $?
mkfs.ext4 -L ROOT /dev/loop7 || exit $?
losetup -d /dev/loop7 || exit $?
echo "...done"

# mount partitions
echo "mounting partitions..."
mkdir -p mnt/root
mount -o loop,offset=$((206848*512)) ${IMAGE} mnt/root || exit $?
mkdir -p mnt/root/boot
mount -o loop,offset=$((2048*512)) ${IMAGE} mnt/root/boot || exit $?
echo "...done"

# populate ROOT
echo "populate root..."
rsync -a ${ROOT}/ mnt/root/

# populate BOOT
echo "populate boot..."
cat <<EOF >mnt/root/boot/config.txt
kernel=kernel.img
arm_freq=800
core_freq=250
sdram_freq=400
over_voltage=0
gpu_mem=16
EOF

cat <<EOF >mnt/root/boot/cmdline.txt
dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 elevator=deadline root=/dev/mmcblk0p2 rootfstype=ext4 rootwait
EOF
 
umount mnt/root/boot
umount mnt/root
rm -r mnt

rm -f ${IMAGE}.bz2
echo "compressing image..."
bzip2 -9 ${IMAGE}
echo "...done"
