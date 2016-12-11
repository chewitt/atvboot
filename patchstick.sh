#!/bin/bash

################################################################################
#  This file is part of LibreELEC - https://libreelec.tv
#  Copyright (C) 2011-2016 Christian Hewitt (chewitt@libreelec.tv)
#
#  This Program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2, or (at your option)
#  any later version.
#
#  This Program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with LibreELEC; see the file COPYING.  If not, write to
#  the Free Software Foundation, 51 Franklin Street, Suite 500, Boston, MA 02110, USA.
#  http://www.gnu.org/copyleft/gpl.html
################################################################################

blink(){
  atvclient &>/dev/null &
}

check_verbose(){
  exec 1>/dev/console
  exec 2>/dev/console
  if [ -f /mnt/openelec/enable_verbose ]; then
    exec 3>&1
    exec 4>&2
  else
    exec 3> /dev/null
    exec 4> /dev/null
  fi
}

check_debug(){
  if [ -f /mnt/rootfs/enable_debug ]; then
    echo "        INFO: Script debugging enabled"
    set -x
  fi
}

check_function(){
  FUNCTION=$(cat /mnt/rootfs/function)
}

check_bootdevice(){
  SDA=$(ls /dev/sda)
  SDB=$(ls /dev/sdb)
  BOOTDEVICE=$(grep /mnt/rootfs /proc/mounts | awk '{print $1}' | sed 's/[0-9]//g')
  if [ -n "${SDA}" ] && [ -n "${SDB}" ]; then
    # AppleTV has USB and HDD devices
    if [ "${BOOTDEVICE}" = "/dev/sda" ]; then
      # AppleTV has a SATA adapter the kernel recognises slowly
      USB="/dev/sda"
      HDD="/dev/sdb"
      SLOWBOOT="TRUE"
    else
      # AppleTV has a normal setup
      USB="/dev/sdb"
      HDD="/dev/sda"
    fi
  else
    # AppleTV has no HDD
    USB="/dev/sda"
    HDD="/dev/sda"
    NOHDD="TRUE"
  fi
}

banner(){
  clear
  echo ""
  echo ""
  echo ""
  echo "        *********************************************************************************"
  echo "        *                                                                               *"
  case $FUNCTION in
    factoryrestore) echo "        *                       LibreELEC AppleTV Factory Restore                       *" ;;
    update)         echo "        *                            LibreELEC AppleTV Updater                          *" ;;
    emergency)      echo "        *                        LibreELEC AppleTV Emergency Boot                       *" ;;
    *)              echo "        *                           LibreELEC AppleTV Installer                         *" ;;
  esac
  echo "        *                                                                               *"
  echo "        *********************************************************************************"
  echo ""
}

disk_sync(){
  partprobe "${TARGET}" 1>&3 2>&4
  sync 1>&3 2>&4
}

network(){
  ifconfig eth0 0.0.0.0
  /sbin/udhcpc --now 1>&3 2>&4
  sleep 4
  IPADDRESS=$(ifconfig | head -n 2 | grep inet | awk '{print $2}' | sed 's/addr://g')
  if [ "${IPADDRESS}" = "" ]; then
    ERROR="noipaddress"
    error
  else
    echo "        INFO: Leased ipv4 address ${IPADDRESS} from DHCP server"
  fi
}

prepare(){
  case $FUNCTION in
    factoryrestore)
      if [ ! -d /mnt/rootfs/restore ]; then
        echo ""
        echo "        FAIL: No restore files!"
        echo ""
        error
      fi
    ;;
    *)
      if [ ! -f /mnt/rootfs/MACH_KERNEL ] && [ ! -f /mnt/rootfs/SYSTEM ]; then
        network
        DOWNLOAD=$(wget -qO- "http://update.libreelec.tv/updates.php?i=INSTALLER&d=LibreELEC&pa=ATV.i386&v=7.0.0" | \
                   sed -e 's/^.*"update":"\([^"]*\)".*$/\1/' | grep ATV)
        echo ""
        echo "        INFO: Downloading ${DOWNLOAD}"
        echo ""
        wget -O /mnt/rootfs/"${DOWNLOAD}" http://releases.libreelec.tv/"${DOWNLOAD}"
        tar -xvf /mnt/rootfs/"${DOWNLOAD}" -C /mnt/rootfs 1>&3 2>&4
	FOLDER=$(echo "${DOWNLOAD}" | sed 's/.tar//g')
        mv /mnt/rootfs/"${FOLDER}"/target/MACH_KERNEL /mnt/rootfs/ 1>&3 2>&4
        mv /mnt/rootfs/"${FOLDER}"/target/MACH_KERNEL.md5 /mnt/rootfs/ 1>&3 2>&4
        mv /mnt/rootfs/"${FOLDER}"/target/SYSTEM /mnt/rootfs/ 1>&3 2>&4
        mv /mnt/rootfs/"${FOLDER}"/target/SYSTEM.md5 /mnt/rootfs/ 1>&3 2>&4
        rm -rf /mnt/rootfs/"${FOLDER}" 1>&3 2>&4
      fi
      echo "        INFO: Validating Checksums"
      SUM1=$(md5sum /mnt/rootfs/MACH_KERNEL | awk '{print $1}')
      SUM2=$(awk '{print $1}' /mnt/rootfs/MACH_KERNEL.md5)
      SUM3=$(md5sum /mnt/rootfs/SYSTEM | awk '{print $1}')
      SUM4=$(awk '{print $1}' /mnt/rootfs/SYSTEM.md5)
      if [ "${SUM1}" != "${SUM2}" ] || [ "${SUM3}" != "${SUM4}" ] || [ -z "${SUM2}" ] || [ -z "${SUM4}" ]; then
        ERROR="badchecksum"
        error
      fi
      rm /mnt/rootfs/MACH_KERNEL.md5 1>&3 2>&4
      rm /mnt/rootfs/SYSTEM.md5 1>&3 2>&4
    ;;
  esac
}

create_target(){
  echo ""
  dd if=/dev/zero of="${TARGET}" bs=512 count=40 1>&3 2>&4
  disk_sync
  echo "        INFO: Creating GPT Scheme"
  parted -s "${TARGET}" mklabel gpt 1>&3 2>&4
}

create_boot(){
  echo "        INFO: Creating BOOT Partition"
  parted -s "${TARGET}" mkpart primary HFS 40s 512M 1>&3 2>&4
  parted -s "${TARGET}" set 1 atvrecv on 1>&3 2>&4
  parted -s "${TARGET}" name 1 'BOOT' 1>&3 2>&4
  disk_sync
  mkfs.hfsplus -s -v "BOOT" "${TARGET}"1 1>&3 2>&4
  fsck.hfsplus -y "${TARGET}"1 1>&3 2>&4
  BOOT=$(mktemp -d "/tmp/mounts.XXXXXX")
  mount "${TARGET}"1 "${BOOT}" 1>&3 2>&4
}

create_boot_usb(){
  echo "        INFO: Creating BOOT Partition"
  parted -s "${TARGET}" mkpart primary HFS 40s 1048542s 1>&3 2>&4
  parted -s "${TARGET}" set 1 atvrecv on 1>&3 2>&4
  parted -s "${TARGET}" name 1 'BOOT' 1>&3 2>&4
  disk_sync
}

create_swap(){
  echo "        INFO: Creating SWAP Partition"
  P1_END=$(parted -s "${TARGET}" unit s print | grep BOOT | awk '{print $3}' | sed 's/s//g')
  P2_START=$(( P1_END + 1 ))
  parted -s "${TARGET}" mkpart primary linux-swap "${P2_START}"s 1024M 1>&3 2>&4
  parted -s "${TARGET}" name 2 'SWAP' 1>&3 2>&4
  mkswap "${TARGET}"2 1>&3 2>&4
  disk_sync
}

create_storage(){
  echo "        INFO: Creating STORAGE Partition"
  P2_END=$(parted -s "${TARGET}" unit s print | grep SWAP | awk '{print $3}' | sed 's/s//g')
  P3_START=$(( P2_END + 1 ))
  P3_END=$(parted -s "${TARGET}" unit s print | grep "${TARGET}" | awk '{print $3}' | sed 's/s//g')
  P3_END=$(( P3_END - 40 ))
  parted -s "${TARGET}" mkpart primary ext4 "${P3_START}"s 100% 1>&3 2>&4
  parted -s "${TARGET}" name 3 'STORAGE' 1>&3 2>&4
  disk_sync
  mkfs.ext4 -L "STORAGE" "${TARGET}"3 1>&3 2>&4
  fsck.ext4 -y "${TARGET}"3 1>&3 2>&4
  STORAGE=$(mktemp -d "/tmp/mounts.XXXXXX")
  mount "${TARGET}"3 "${STORAGE}" 1>&3 2>&4
}

install_hdd(){
  TARGET=${HDD}
  echo ""
  echo "        WARN: Continuing with installation will replace your original Apple OS or current"
  echo "              Linux OS on the AppleTV's internal hard drive with LibreELEC. If you do not"
  echo "              want installation to contine please POWER OFF! your AppleTV within the next"
  echo "              30 seconds and remove the USB key."
  sleep 30
  create_target
  create_boot
  create_swap
  create_storage
  echo "        INFO: Creating BOOT Files"
  cp -av /mnt/rootfs/boot.efi "${BOOT}"/ 1>&3 2>&4
  cp -av /mnt/rootfs/BootLogo.png "${BOOT}"/ 1>&3 2>&4
  cp -Rv /mnt/rootfs/System "${BOOT}"/ 1>&3 2>&4
  cp -av /mnt/rootfs/MACH_KERNEL "${BOOT}"/ 1>&3 2>&4
  cp -av /mnt/rootfs/SYSTEM "${BOOT}"/ 1>&3 2>&4
  if [ "${SLOWBOOT}" = "TRUE" ]; then
    cp -av /mnt/rootfs/com.apple.Boot.usb "${BOOT}"/com.apple.Boot.plist 1>&3 2>&4
  else
    cp -av /mnt/rootfs/com.apple.Boot.hdd "${BOOT}"/com.apple.Boot.plist 1>&3 2>&4
  fi
  chown root:root "${BOOT}"/* 1>&3 2>&4
  echo "        INFO: Creating STORAGE Files"
  mkdir -p "${STORAGE}"/.cache/services 1>&3 2>&4
  mkdir -p "${STORAGE}"/.kodi/userdata 1>&3 2>&4
  mkdir -p "${STORAGE}"/.update 1>&3 2>&4
  touch "${STORAGE}"/.cache/services/crond.disabled
  touch "${STORAGE}"/.cache/services/samba.disabled
  touch "${STORAGE}"/.cache/services/avahi.disabled
  echo SSHD_START=true > "${STORAGE}"/.cache/services/ssh.conf
  echo SSHD_DISABLE_PW_AUTH=false > "${STORAGE}"/.cache/services/sshd.conf
  echo SSH_ARGS= >> "${STORAGE}"/.cache/services/sshd.conf
  cp -av /mnt/rootfs/10s.mp4 "${STORAGE}"/.cache 1>&3 2>&4
  cp -av /mnt/rootfs/guisettings.xml "${STORAGE}"/.kodi/userdata 1>&3 2>&4
  echo ""
  echo "        INFO: Installation Completed!"
  echo ""
  echo "        INFO: Ignore the warnings below as we reboot :)"
  echo ""
}

install_usb(){
  TARGET=${USB}
  create_target
  create_boot_usb
  create_swap
  create_storage
  echo "        INFO: Creating BOOT Files"
  if [ "${NOHDD}" = "TRUE" ]; then
    cp -av /mnt/rootfs/com.apple.Boot.hdd /mnt/rootfs/com.apple.Boot.plist 1>&3 2>&4
  else
    cp -av /mnt/rootfs/com.apple.Boot.usb /mnt/rootfs/com.apple.Boot.plist 1>&3 2>&4
  fi
  rm /mnt/rootfs/mach_kernel 1>&3 2>&4
  chown root:root /mnt/rootfs/* 1>&3 2>&4
  echo "        INFO: Creating STORAGE Files"
  mkdir -p "${STORAGE}"/.cache/services 1>&3 2>&4
  mkdir -p "${STORAGE}"/.kodi/userdata 1>&3 2>&4
  mkdir -p "${STORAGE}"/.update 1>&3 2>&4
  touch "${STORAGE}"/.cache/services/crond.disabled
  touch "${STORAGE}"/.cache/services/samba.disabled
  touch "${STORAGE}"/.cache/services/avahi.disabled
  echo SSHD_START=true > "${STORAGE}"/.cache/services/ssh.conf
  echo SSHD_DISABLE_PW_AUTH=false > "${STORAGE}"/.cache/services/sshd.conf
  echo SSH_ARGS= >> "${STORAGE}"/.cache/services/sshd.conf
  cp -av /mnt/rootfs/10s.mp4 "${STORAGE}"/.cache 1>&3 2>&4
  cp -av /mnt/rootfs/guisettings.xml "${STORAGE}"/.kodi/userdata 1>&3 2>&4
  echo ""
  echo "        INFO: Installation Completed!"
  echo ""
  echo "        INFO: Ignore the warnings below as we reboot :)"
  echo ""
}

update(){
  echo ""
  echo "        INFO: Checking ${HDD}1 Filesystem for Errors"
  fsck.hfsplus ${HDD}1 1>&3 2>&4
  mkdir -p /mnt/boot 1>&3 2>&4
  echo "        INFO: Mounting BOOT Partition"
  mount -t hfsplus -o rw,force ${HDD}1 /mnt/boot 1>&3 2>&4
  echo "        INFO: Updating MACH_KERNEL and SYSTEM"
  cp -av /mnt/rootfs/MACH_KERNEL /mnt/boot/ 1>&3 2>&4
  cp -av /mnt/rootfs/SYSTEM /mnt/boot/ 1>&3 2>&4
  echo ""
  echo "        INFO: Files updated!"
  echo ""
  echo "        INFO: Ignore the warnings below as we reboot :)"
  echo ""
}

factoryrestore(){
  DISKSIZE=$(parted -s ${HDD} unit s print | grep "Disk ${HDD}:" | awk '{print $3}' | sed 's/s//g')
  SECTORS=$(( DISKSIZE - 262145 ))
  echo "        WARN: Continuing with restore will erase LibreELEC from the internal HDD of your"
  echo "              AppleTV and will reinstall AppleOS files to prepare for a factory-restore"
  echo "              boot. To abort the restore, POWER OFF! your AppleTV in the next 30 seconds"
  echo ""
  sleep 30
  echo "        INFO: Creating GPT Scheme"
  parted -s ${HDD} mklabel gpt 1>&3 2>&4
  echo "        INFO: Creating Partitions"
  parted -s ${HDD} mkpart primary fat32 40s 69671s 1>&3 2>&4
  parted -s ${HDD} mkpart primary HFS 69672s 888823s 1>&3 2>&4
  parted -s ${HDD} mkpart primary HFS 888824s 2732015s 1>&3 2>&4
  parted -s ${HDD} mkpart primary HFS 2732016s ${SECTORS}s 1>&3 2>&4
  partprobe ${HDD} 1>&3 2>&4
  parted -s ${HDD} set 2 atvrecv on 1>&3 2>&4
  parted -s ${HDD} set 1 boot on 1>&3 2>&4
  echo "        INFO: Creating Filesystems"
  mkfs.msdos -F 32 -n EFI ${HDD}1 1>&3 2>&4
  mkfs.hfsplus -v Recovery ${HDD}2 1>&3 2>&4
  mkfs.hfsplus -J -v OSBoot ${HDD}3 1>&3 2>&4
  mkfs.hfsplus -J -v Media ${HDD}4 1>&3 2>&4
  partprobe ${HDD} 1>&3 2>&4
  echo "        INFO: Creating Partition Names"
  parted -s ${HDD} name 1 'EFI' 1>&3 2>&4
  parted -s ${HDD} name 2 'Recovery' 1>&3 2>&4
  parted -s ${HDD} name 3 'OSBoot' 1>&3 2>&4
  parted -s ${HDD} name 4 'Media' 1>&3 2>&4
  partprobe ${HDD} 1>&3 2>&4
  echo "        INFO: Restoring Recovery Files"
  mkdir /mnt/Recovery 1>&3 2>&4
  mount -t hfsplus -o rw,force ${HDD}2 /mnt/Recovery 1>&3 2>&4
  cp -Rv /mnt/rootfs/restore/* /mnt/Recovery 1>&3 2>&4
  sync 1>&3 2>&4
  sleep 2
  umount /mnt/Recovery 1>&3 2>&4
  sleep 2
  echo y | gptsync ${HDD} 1>&3 2>&4
  sleep 2
  echo ""
  echo "        INFO: Preparation has completed!"
  echo ""
  echo "        INFO: Ignore the warnings below as we reboot :)"
  echo ""
}

emergency(){
  echo ""
  echo "        INFO: Telnet login available; user = 'root' and password = 'root'"
  echo "" 
  telnetd -l /bin/login
}

cleanup(){
  disk_sync
  sleep 2
  for i in `find /tmp -name mounts.*` ; do
    umount $i
    sleep 2
  done
  umount /mnt/rootfs 1>&3 2>&4
  sleep 2
  fsck.hfsplus -y "${TARGET}"1 1>&3 2>&4
  fsck.ext4 -y "${TARGET}"3 1>&3 2>&4
  sleep 2
  echo y | gptsync ${TARGET} 1>&3 2>&4
  if [ "${FUNCTION}" = "install-hdd" ]; then
    dd if=/dev/zero of=${USB} bs=512 count=40 1>&3 2>&4
  fi
}

snooze(){
  sleep 100000
}

pause(){
  sleep 10
}

error(){
  case $ERROR in
    download)    echo "        FAIL: The files could not be downloaded, aborting!";;
    badchecksum) echo "        FAIL: Checksum does not match, aborting!";;
    noipaddress) echo "        FAIL: Failed to lease an ipv4 address, aborting!";;
    *)           echo "        FAIL: There was an error, aborting!";;
  esac
  echo ""
  if [ -z "${IPADDRESS}" ]; then
    network
  fi
  emergency
  snooze
}

main(){
  blink
  check_verbose
  check_debug
  check_function
  check_bootdevice
  banner
  case $FUNCTION in
    install-hdd)
      prepare
      install_hdd
      cleanup
      pause
      reboot
      ;;
    install-usb)
      prepare
      install_usb
      cleanup
      pause
      reboot
      ;;
    update)
      prepare
      update
      cleanup
      pause
      reboot
      ;;
    factoryrestore)
      prepare
      factoryrestore
      cleanup
      pause
      reboot
      ;;
    *)
      network
      emergency
      ;;
  esac
}

main
snooze
