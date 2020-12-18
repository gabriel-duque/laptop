#!/bin/sh

set -eu

# Here are the variables which can be changed

disk=""

esp_part_name="arch-esp"
esp_part_size="256MiB"
esp_fs_label="arch-esp"

luks_part_name="arch-crypt"
luks_part_label="arch-crypt"
#luks_dm_name="arch-crypt"
luks_dm_name="arch-crypt-test"
luks_dm_dev="/dev/mapper/$luks_dm_name"
luks_cipher="aes-xts-plain64"
luks_hash="sha512"
luks_key_size="512"

sys_fs_label="arch-sys"

#swapfile_size="$(free -b | awk '/^Mem:/ {print $2}')"
swapfile_size="$(free | awk '/^Mem:/ {print $2}')"
swapfile_label="arch-swap"

hostname="slowbro"
timezone="Europe/Paris"
locale="en_US.UTF-8"

btrfs_opts="compress=zstd,discard"

# You shouldn't need to edit anything below here

# Run a command without stdout or stderr
quiet() {
  "$@" >/dev/null 2>&1
}

log() {
  printf '[\e[32m*\e[39m] %s\n' "$*"
}

die() {
  printf '[\e[31m*\e[39m] %s\n' "$*"
  exit 1
}

chroot_log() {
  printf "(chroot) "
  log "$*"
}

chroot_log() {
  printf "(chroot) "
  die "$*"
}

initial_checks() {
  if ! test -d "/sys/firmware/efi"; then
    die "It looks like you did not boot in EFI mode."
  fi
  log "Boot mode check succeeded."

  if ! nc -z archlinux.org 80; then
    die "Your network connection doesn't seem to be working."
  fi
  log "Network check succeeded."
}

get_confirmation() {
  echo "Beware: $*"
  printf "Do you wish to continue? (y/N) "
  read -r answer

  if echo "$answer" | grep -q '^\s*[nN]'; then
    echo "Aborting."
    exit 0
  fi
}

root_passwd_prompt() {
  passwd=
  confirmation=

  while test "$passwd" != "$confirmation" || test "${#passwd}" -eq 0; do
    echo "Enter root password (password will not be echoed):"
    stty -echo
    read -r passwd
    stty echo

    echo "Enter the same password again:"
    stty -echo
    read -r confirmation
    stty echo
  done

  root_passwd="$passwd"
}

luks_passwd_prompt() {
  passwd=
  confirmation=

  while test "$passwd" != "$confirmation" || test "${#passwd}" -eq 0; do
    echo "Enter LUKS password (password will not be echoed):"
    stty -echo
    read -r passwd
    stty echo

    echo "Enter the same password again:"
    stty -echo
    read -r confirmation
    stty echo
  done

  luks_passwd="$passwd"
}

host_setup() {
  timedatectl set-ntp true
  log "Enabled NTP"

  quiet pacman -Syu --noconfirm
  log "Updated host packages"

  quiet pacman -S --noconfirm --needed - < "bootstrap/host_pkg_list"
  log "Installed necessary host packages"

  echo "Ranking mirrors, this can take some time..."
  temp_mirrorlist="$(mktemp)"
  cp /etc/pacman.d/mirrorlist "$temp_mirrorlist"
  rankmirrors "${temp_mirrorlist}" > /etc/pacman.d/mirrorlist
  rm -f "$temp_mirrorlist"
  log "Ranked mirrors by speed"
}

get_disk() {
  lsblk --output NAME,PATH,SIZE | awk 'NR>1 && !/^[^0-9a-zA-Z]/ {print $2, $3}'
  printf "On which disk do you wish to install Arch Linux? "
  read -r disk
}

partition_disk() {
  wipefs -qaf "$disk"
  partprobe "$disk"
  log "Wiped $disk"

  parted --align optimal --script "$disk" \
    mklabel gpt \
    mkpart primary "0%" "$esp_part_size" \
    name 1 "$esp_part_name" \
    set 1 esp on \
    mkpart primary "$esp_part_size" "100%" \
    name 2 "$luks_part_name"
  partprobe "$disk"
  log "Partitioned $disk"
}

make_filesystems() {
  tmp_out="$(lsblk --output PATH "$disk" | sed '1,2d')"
  esp_part_dev="$(echo "$tmp_out" | sed '1q;d')"
  crypt_part_dev="$(echo "$tmp_out" | sed '2q;d')"
  printf "%s" "$luks_passwd" | cryptsetup --batch-mode \
                                 luksFormat \
                                 --key-file "-" \
                                 --cipher "$luks_cipher" \
                                 --key-size "$luks_key_size" \
                                 --hash "$luks_hash" \
                                 --type luks2 \
                                 --label "$luks_part_label" \
                                 --use-random \
                                 "$crypt_part_dev"
  log "Initialized LUKS partition on $crypt_part_dev"

  printf "%s" "$luks_passwd" | cryptsetup --batch-mode \
                                 luksOpen \
                                 --key-file "-" \
                                 "$crypt_part_dev" \
                                 "$luks_dm_name"
  log "Opened LUKS partition on $crypt_part_dev"

  quiet mkfs.vfat \
          -F32 \
          -n "$esp_fs_label" \
          "$esp_part_dev"
  log "Created FAT32 filesystem on $esp_part_dev"

  mkfs.btrfs \
    --quiet \
    -L "$sys_fs_label" \
    "$luks_dm_dev"
  log "Created BTRFS filesystem on $luks_dm_dev"

  temp_mountpoint="$(mktemp -d)"
  quiet mount -o "$btrfs_opts" "$luks_dm_dev" "$temp_mountpoint"
  quiet btrfs subvolume create "${temp_mountpoint}/@root"
  log "Created @root BTRFS subvolume"

  quiet btrfs subvolume create "${temp_mountpoint}/@home"
  log "Created @home BTRFS subvolume"

  quiet btrfs subvolume create "${temp_mountpoint}/@swap"
  log "Created @swap BTRFS subvolume"

  touch "${temp_mountpoint}/@swap/swapfile"
  chattr +C "${temp_mountpoint}/@swap/swapfile"
  fallocate -l "$swapfile_size" "${temp_mountpoint}/@swap/swapfile"
  quiet mkswap -L "$swapfile_label" "${temp_mountpoint}/@swap/swapfile"
  log "Created swap file of size $swapfile_size on @swap subvolume"

  quiet btrfs subvolume create "${temp_mountpoint}/@snapshots"
  log "Created @snapshots BTRFS subvolume"

  umount "${temp_mountpoint}"
  rm -rf "${temp_mountpoint}"
}

mount_filesystems() {
  quiet mount \
          -o "${btrfs_opts},subvol=@root" \
          "/dev/disk/by-label/$sys_fs_label" "/mnt"
  log "Mounted @root subvolume on /mnt"

  mkdir -p /mnt/boot/efi /mnt/home /mnt/swap /mnt/.snapshots
  quiet mount "/dev/disk/by-label/$esp_fs_label" "/mnt/boot/efi"

  quiet mount \
          -o "${btrfs_opts},subvol=@home" \
          "/dev/disk/by-label/$sys_fs_label" "/mnt/home"
  log "Mounted @home subvolume on /mnt/home"

  quiet mount \
          -o "${btrfs_opts},subvol=@swap" \
          "/dev/disk/by-label/$sys_fs_label" "/mnt/swap"
  log "Mounted @swap subvolume on /mnt/swap"

  quiet mount \
          -o "${btrfs_opts},subvol=@snapshots" \
          "/dev/disk/by-label/$sys_fs_label" "/mnt/.snapshots"
  log "Mounted @snapshots subvolume on /mnt/.snapshots"

  quiet swapon /mnt/swap/swapfile
  log "Swapon'ed /mnt/swap/swapfile"
}

bootstrap_new_system() {
  echo "Installing bootstrap guest packages, this can take some time..."
  quiet pacstrap /mnt - < "bootstrap/pacstrap_pkg_list"
  log "Installed bootstrap guest packages"
}

run_chroot_script() {
  if test -n "$root_passwd"; then
    export root_passwd
  fi
  export luks_passwd

  echo "In chroot"
}

cleanup() {
  echo "Cleaning up"
}

do_install() {
  initial_checks
  get_confirmation "This script WILL wipe your disks."
  root_passwd_prompt
  luks_passwd_prompt
  host_setup

  until test -b "$disk"; do
    get_disk
  done

  get_confirmation "You are about to wipe ${disk}."
  partition_disk
  make_filesystems
  mount_filesystems
  bootstrap_new_system

  get_confirmation "Initial setup is done. Run the 'chroot.sh' script?"

  run_chroot_script
  cleanup
}

do_install
