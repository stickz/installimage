#!/bin/bash

#
# Gentoo specific functions
#
# (c) 2008-2021, Hetzner Online GmbH
#


# generate_config_mdadm "NIL"
generate_config_mdadm() {
  local mdadmconf="/etc/mdadm/mdadm.conf"
  execute_chroot_command "/usr/share/mdadm/mkconf > $mdadmconf"; declare -i EXITCODE=$?

  #
  # Enable mdadm
  #
  local mdadmdefconf="$FOLD/hdd/etc/default/mdadm"
  sed -i "s/AUTOCHECK=false/AUTOCHECK=true # modified by installimage/" \
    "$mdadmdefconf"
  sed -i "s/AUTOSTART=false/AUTOSTART=true # modified by installimage/" \
    "$mdadmdefconf"
  sed -i "s/START_DAEMON=false/START_DAEMON=true # modified by installimage/" \
    "$mdadmdefconf"
  sed -i -e "s/^INITRDSTART=.*/INITRDSTART='all' # modified by installimage/" \
    "$mdadmdefconf"

  return "$EXITCODE"
}


# generate_new_ramdisk "NIL"
generate_new_ramdisk() {
  if [ -n "$1" ]; then
    local outfile; outfile=$(find "$FOLD"/hdd/boot -name "initrd.img-*" -not -regex ".*\(gz\|bak\)" -printf "%f\n" | sort -nr | head -n1)
    local kvers; kvers=$(echo "$outfile" |cut -d "-" -f2-)
    debug "# Kernel Version found: $kvers"

    if [ "$IMG_VERSION" -ge 60 ]; then
      local blacklist_conf="$FOLD/hdd/etc/modprobe.d/blacklist-$C_SHORT.conf"
      # blacklist various driver due to bugs and stability issues
      {
        echo "### $COMPANY - installimage"
        echo "### silence any onboard speaker"
        echo "blacklist pcspkr"
        echo "blacklist snd_pcsp"
        echo "### i915 driver blacklisted due to various bugs"
        echo "### especially in combination with nomodeset"
        echo "blacklist i915"
        echo "### mei driver blacklisted due to serious bugs"
        echo "blacklist mei"
        echo "blacklist mei-me"
        echo "blacklist sm750fb"
      } > "$blacklist_conf"
    fi

    # apparently sometimes the mdadm assembly bugfix introduced with the recent mdadm release does not work
    # however, the problem is limited to H8SGL boards
    # see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=784070
    if [ "$MBTYPE" = 'H8SGL' ]; then
      local script="$FOLD/hdd/usr/share/initramfs-tools/scripts/local-block/mdadmpatch"
      cp "$SCRIPTPATH/h8sgl-deb8-md.sh" "$script"
      chmod a+x "$script"
    fi

    # just make sure that we do not accidentally try to install a bootloader
    # when we haven't configured grub yet
    # Debian won't install a boot loader anyway, but display an error message,
    # that needs to be confirmed
    sed -i "s/do_bootloader = yes/do_bootloader = no/" "$FOLD/hdd/etc/kernel-img.conf"

    # well, we might just as well update all initramfs and stop findling around
    # to find out which kernel version is the latest
    execute_chroot_command "update-initramfs -u -k $kvers"; EXITCODE=$?

    return "$EXITCODE"
  fi
}

#
# Generate the GRUB bootloader configuration.
#
generate_config_grub() {
  declare -i EXITCODE=0

  local grubdefconf="$FOLD/hdd/etc/default/grub"

  # set linux_default in grub
  local grub_linux_default="nomodeset consoleblank=0"
  if is_virtual_machine; then
     grub_linux_default="${grub_linux_default} elevator=noop"
  fi

  if has_threadripper_cpu; then
    grub_linux_default+=' pci=nommconf'
  fi

  if is_dell_r6415; then
    grub_linux_default=${grub_linux_default/nomodeset }
  fi

  if [ "$SYSARCH" == "arm64" ]; then
    grub_linux_default+=' console=ttyAMA0 console=tty0'
  fi

  sed -i "$grubdefconf" -e "s/^GRUB_HIDDEN_TIMEOUT=.*/GRUB_HIDDEN_TIMEOUT=5/" -e "s/^GRUB_HIDDEN_TIMEOUT_QUIET=.*/GRUB_HIDDEN_TIMEOUT_QUIET=false/"
  sed -i "$grubdefconf" -e "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"${grub_linux_default}\"/"

  rm "$FOLD/hdd/boot/grub/grub.cfg"

  if [ "$UEFI" -eq 1 ]; then
    execute_chroot_command "echo 'set grub2/update_nvram false' | debconf-communicate -f noninteractive"
    execute_chroot_command "echo 'set grub2/force_efi_extra_removable true' | debconf-communicate -f noninteractive"
  fi

  execute_chroot_command "grub-mkconfig -o /boot/grub/grub.cfg 2>&1"
  if [ "$UEFI" -eq 1 ]; then
    local efi_target="${SYSARCH}-efi"
    local efi_dir="/boot/efi"
    local efi_grub_options="--no-floppy --no-nvram --removable"
    execute_chroot_command "grub-install --target=${efi_target} --efi-directory=${efi_dir} ${efi_grub_options} 2>&1"
    declare -i EXITCODE=$?
  else
    # only install grub2 in mbr of all other drives if we use swraid
    for ((i=1; i<=COUNT_DRIVES; i++)); do
      if [ "$SWRAID" -eq 1 ] || [ "$i" -eq 1 ] ;  then
        local disk; disk="$(eval echo "\$DRIVE"$i)"
        execute_chroot_command "grub-install --no-floppy --recheck $disk 2>&1"
      fi
    done
  fi

  if ((IMG_VERSION >= 70)); then
    debconf_set_grub_install_devices #|| return 1
  fi

  uuid_bugfix

  PARTNUM=$(echo "$SYSTEMBOOTDEVICE" | rev | cut -c1)

  if [ "$SWRAID" = "0" ]; then
    PARTNUM="$((PARTNUM - 1))"
  fi

  delete_grub_device_map

  return "$EXITCODE"
}

delete_grub_device_map() {
  [ -f "$FOLD/hdd/boot/grub/device.map" ] && rm "$FOLD/hdd/boot/grub/device.map"
}

#
# os specific functions
# for purpose of e.g. debian-sys-maint mysql user password in debian/ubuntu LAMP
#
run_os_specific_functions() {
  randomize_mdadm_array_check_time

  if hetzner_lamp_install; then
    setup_hetzner_lamp || return 1
  fi
  
  # Setup mdadm for Gentoo. Add to boot run level. Double array sync speed.
  execute_chroot_command "rc-update add mdraid boot"
  execute_chroot_command "echo 400000 > /proc/sys/dev/raid/speed_limit_max"
  execute_chroot_command "chown root /var/empty"

  [[ -e "$FOLD/hdd/var/spool/exim4/input" ]] && find "$FOLD/hdd/var/spool/exim4/input" -type f -delete

  disable_resume
  return 0
}

# vim: ai:ts=2:sw=2:et
