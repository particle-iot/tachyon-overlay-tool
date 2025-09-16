#!/bin/bash
set -euo pipefail

if [ "${DEBUG:-}" = "true" ]; then
  set -x
fi

usage() {
  echo "Usage: $0 -f <filesystem> -s <stack> -r <resources> -d <debug> [-e <env_list>]"
  echo "  -f <filesystem>: Path to the filesystem image to modify."
  echo "  -r <resources>:  Path to extra resources directory."
  echo "  -s <stack>:      Stack name of the overlay stack to apply."
  echo "  -d <debug>:      true | false | chroot — Debug mode (optional)."
  echo "  -e <env_list>:   Comma-separated list of KEY=VALUE pairs to set inside chroot (optional)."
  exit 1
}

# --- Parse args ---------------------------------------------------------------
DEBUG="false"
FILESYSTEM=""
RESOURCES=""
STACK=""
ENV_LIST="${ENV_LIST:-}"

while getopts ":f:r:d:s:e:" opt; do
  case $opt in
    f) FILESYSTEM="$OPTARG" ;;
    r) RESOURCES="$OPTARG" ;;
    d) DEBUG="$OPTARG" ;;
    s) STACK="$OPTARG" ;;
    e) ENV_LIST="$OPTARG" ;;
    *) usage ;;
  esac
done

# ENV_LIST contains "KEY=VAL,KEY2=VAL2,..."
if [ -n "${ENV_LIST:-}" ]; then
  OLDIFS="$IFS"; IFS=',' 
  for kv in $ENV_LIST; do 
    # trim whitespace and export
    kv="$(echo "$kv" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$kv" ] && export "$kv"
  done
  IFS="$OLDIFS"
fi

[ -n "${FILESYSTEM:-}" ] && [ -n "${STACK:-}" ] && [ -n "${RESOURCES:-}" ] || usage

# --- Safe defaults / PATH -----------------------------------------------------
TMP_DIR="${TMP_DIR:-/tmp/work}"
MOUNT_POINT="/mnt/tachyon"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# --- Print args -----------------------------------------------------

echo "    FILESYSTEM: $FILESYSTEM"
echo "    RESOURCES : $RESOURCES"
echo "    STACK     : $STACK"
echo "    DEBUG     : $DEBUG"
echo "    ENV_LIST  : $ENV_LIST"

# # --- Install tools on demand --------------------------------------------------
# need_packages=()
# need() { command -v "$1" >/dev/null 2>&1 || need_packages+=("$2"); }

# need losetup     util-linux
# need partx       util-linux
# need kpartx      kpartx
# need mkfs.vfat   dosfstools
# need e2fsck      e2fsprogs
# need resize2fs   e2fsprogs
# if ! command -v sgdisk >/dev/null 2>&1 && ! command -v parted >/dev/null 2>&1; then
#   need parted parted
# fi

# if ((${#need_packages[@]})); then
#   echo "Installing packages: ${need_packages[*]} ..."
#   sudo apt-get update -y
#   sudo apt-get install -y "${need_packages[@]}"
# fi

# --- Checks -------------------------------------------------------------------
if [ ! -f "$FILESYSTEM" ]; then
  echo "Error: Filesystem '$FILESYSTEM' does not exist." >&2
  exit 1
fi

# --- is_disk_image -----------------------------------------------------------------
# Return 0 if the file looks like a full disk image (has a partition table), else 1
is_disk_image() {
  local f="$1"
  # Heuristic 1: file(1) mentions partition tables
  if file -b "$f" 2>/dev/null | grep -qiE 'partition table|GPT|DOS/MBR'; then
    return 0
  fi
  # Heuristic 2: fdisk prints a disklabel or partitions
  if fdisk -l "$f" >/dev/null 2>&1; then
    fdisk -l "$f" 2>/dev/null | grep -qE '^Disklabel type:|^Device\s+' && return 0
  fi
  return 1
}

# --- Detection ---------------------------------------------------------------
ftype="$(file -b "$FILESYSTEM" || true)"
NEEDS_SPARSE=false
if echo "$ftype" | grep -qi 'Android sparse image'; then
  NEEDS_SPARSE=true
fi

echo "==> process-release"
echo "    FILESYSTEM: $FILESYSTEM"
echo "    DEBUG: ${DEBUG:-auto}"
echo "    TYPE: $ftype"
echo "    FLOW: $([ "$NEEDS_SPARSE" = true ] && echo 'sparse->raw' || echo 'raw')"

# --- Helpers -----------------------------------------------------------------
cleanup_mounts() {
  set +e
  sudo umount "$MOUNT_POINT/boot/efi" 2>/dev/null || true
  sudo umount "$MOUNT_POINT/dev/pts" 2>/dev/null || true
  sudo umount "$MOUNT_POINT/run"      2>/dev/null || true
  sudo umount "$MOUNT_POINT/sys"      2>/dev/null || true
  sudo umount "$MOUNT_POINT/proc"     2>/dev/null || true
  sudo umount "$MOUNT_POINT/dev"      2>/dev/null || true
  sudo umount "$MOUNT_POINT"          2>/dev/null || true
  [ -n "${LOOPDEV:-}" ] && {
    sudo partx -d "$LOOPDEV" 2>/dev/null || true
    sudo kpartx -d "$LOOPDEV" 2>/dev/null || true
    sudo losetup -d "$LOOPDEV" 2>/dev/null || true
  }
}
trap cleanup_mounts EXIT

mount_binds() {
  sudo mount --bind /dev     "$MOUNT_POINT/dev"
  sudo mount --bind /proc    "$MOUNT_POINT/proc"
  sudo mount --bind /sys     "$MOUNT_POINT/sys"
  sudo mount --bind /run     "$MOUNT_POINT/run"
  sudo mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
}

find_efi_image() {
  local d; d="$(dirname "$FILESYSTEM")"
  for cand in \
    "$d/efi.img" \
    "$TMP_DIR/input/ubuntu_20_04_image/images/qcm6490/edl/efi.img" \
    "$TMP_DIR/output/images/qcm6490/edl/efi.img"; do
    [ -f "$cand" ] && { echo "$cand"; return 0; }
  done
  return 1
}

# --- Flow A: Android sparse ------------------------------------------
if [ "$NEEDS_SPARSE" = true ]; then
  RAW="${FILESYSTEM}.raw"
  echo "==> Unsparsing to $RAW ..."
  make docker-unsparse-image SYSTEM_IMAGE="$FILESYSTEM" SYSTEM_OUTPUT="$RAW"

  echo "==> Mounting raw filesystem ..."
  sudo mkdir -p "$MOUNT_POINT"
  sudo mount -o loop "$RAW" "$MOUNT_POINT"
  mount_binds

  if EFI_IMAGE="$(find_efi_image)"; then
    echo "Mounting EFI: $EFI_IMAGE"
    sudo mount -o loop "$EFI_IMAGE" "$MOUNT_POINT/boot/efi"
  fi

  if [ -d "$MOUNT_POINT/boot/grub" ]; then
    printf "(hd0) %s\n(hd1) %s\n" "loopback" "loopback" | sudo tee "$MOUNT_POINT/boot/grub/device.map" >/dev/null || true
  fi

  if [ "$DEBUG" = "chroot" ]; then
    echo "Applying stack: $STACK"
    python3 /project/overlay.py apply --overlay-dirs "/tmp/work/input" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
    echo "Entering chroot (debug mode). Type 'exit' to resume..."
    sudo chroot "$MOUNT_POINT" /bin/bash
  elif [ "$DEBUG" = "true" ]; then
    echo "Debugging enabled. Mounted at $MOUNT_POINT"
    echo "To call the overlay, run: python3 /project/overlay.py apply --mount-point $MOUNT_POINT --resources $RESOURCES --stack $STACK"
    /bin/bash
  else
    echo "Applying stack: $STACK"
    python3 /project/overlay.py apply --overlay-dirs "/tmp/work/input" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
  fi

  [ -f "$MOUNT_POINT/boot/grub/device.map" ] && sudo rm -f "$MOUNT_POINT/boot/grub/device.map"
  echo "==> Unmounting ..."
  cleanup_mounts

  echo "==> Re-sparsifying back into $(FILESYSTEM) ..."
  make docker-sparse-image SYSTEM_IMAGE="$FILESYSTEM"

  echo "Done."
  exit 0
fi

# --- Flow B: RAW path ---------------------------------------------------------

# Case B1: FILESYSTEM is a FULL DISK image -> mount its partitions directly
if is_disk_image "$FILESYSTEM"; then
  echo "==> Detected full-disk image; mounting partitions via losetup"
  LOOPDEV="$(sudo losetup -Pf --show "$FILESYSTEM")"
  base="$(basename "$LOOPDEV")"

  # Try kernel-created loopXpN nodes first
  PART_ROOT="${LOOPDEV}p1"
  PART_EFI="${LOOPDEV}p15"

  if [[ ! -e "$PART_ROOT" ]]; then
    sudo partprobe "$LOOPDEV" || true
    command -v udevadm >/dev/null 2>&1 && sudo udevadm settle || true
    sleep 1
  fi

  # Fallback to device-mapper via kpartx if loopXpN still missing
  if [[ ! -e "$PART_ROOT" ]]; then
    sudo kpartx -as "$LOOPDEV"
    PART_ROOT="/dev/mapper/${base}p1"
    PART_EFI="/dev/mapper/${base}p15"
  fi

  # Final fallback: autodetect root (ext4) if the “p1” heuristic fails
  if [[ ! -e "$PART_ROOT" ]]; then
    for dev in /dev/mapper/${base}p* ${LOOPDEV}p*; do
      [[ -e "$dev" ]] || continue
      fstype="$(lsblk -no FSTYPE "$dev" 2>/dev/null || true)"
      if [[ "$fstype" == "ext4" ]]; then PART_ROOT="$dev"; break; fi
    done
  fi

  if [[ ! -e "$PART_ROOT" ]]; then
    echo "ERROR: could not locate root (ext4) partition on $LOOPDEV"
    echo "==> Debug:"
    sudo partx -o NR,START,SECTORS,NAME -g "$LOOPDEV" || true
    lsblk "$LOOPDEV" || true
    exit 1
  fi

  # Autodetect EFI (vfat) if p15 missing/unused
  if [[ ! -e "$PART_EFI" || -z "$(lsblk -no FSTYPE "$PART_EFI" 2>/dev/null | grep -i vfat)" ]]; then
    PART_EFI=""
    for dev in /dev/mapper/${base}p* ${LOOPDEV}p*; do
      [[ -e "$dev" ]] || continue
      fstype="$(lsblk -no FSTYPE "$dev" 2>/dev/null || true)"
      label="$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)"
      if [[ "$fstype" =~ ^(vfat|fat)$ || "$label" =~ ^(EFI|ESP|efi)$ ]]; then
        PART_EFI="$dev"; break
      fi
    done
  fi

  sudo mkdir -p "$MOUNT_POINT"
  echo "==> Mounting root: $PART_ROOT"
  sudo mount "$PART_ROOT" "$MOUNT_POINT"
  mount_binds

  if [[ -n "$PART_EFI" && -e "$PART_EFI" ]]; then
    echo "==> Mounting EFI : $PART_EFI"
    sudo mount "$PART_EFI" "$MOUNT_POINT/boot/efi"
  else
    echo "Note: EFI partition not found; continuing without /boot/efi"
  fi

  if [ -d "$MOUNT_POINT/boot/grub" ]; then
    printf "(hd0) %s\n(hd1) %sp1\n" "$LOOPDEV" "$LOOPDEV" | sudo tee "$MOUNT_POINT/boot/grub/device.map" >/dev/null || true
  fi

  if [ "$DEBUG" = "chroot" ]; then
    echo "Applying stack: $STACK"
    python3 /project/overlay.py apply --overlay-dirs "/tmp/work/input" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
    echo "Entering chroot (debug mode). Type 'exit' to resume..."
    sudo chroot "$MOUNT_POINT" /bin/bash
  elif [ "$DEBUG" = "true" ]; then
    echo "Debugging enabled. Mounted at $MOUNT_POINT"
    echo "To call the overlay, run: python3 /project/overlay.py apply --mount-point $MOUNT_POINT --resources $RESOURCES --stack $STACK"
    /bin/bash
  else
    echo "Applying stack: $STACK"
    python3 /project/overlay.py apply --overlay-dirs "/tmp/work/input" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
  fi

  [ -f "$MOUNT_POINT/boot/grub/device.map" ] && sudo rm -f "$MOUNT_POINT/boot/grub/device.map"
  echo "==> Unmounting ..."
  cleanup_mounts
  echo "Done."
  exit 0
fi

# Case B2: FILESYSTEM is a plain ext4 filesystem image -> mount directly via loop (zero-copy)
echo "==> Mounting ext4 filesystem via loop (zero-copy) ..."
sudo mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$FILESYSTEM" "$MOUNT_POINT"
mount_binds

# Mount EFI image if present (optional)
if EFI_IMAGE="$(find_efi_image)"; then
  echo "Mounting EFI: $EFI_IMAGE"
  sudo mount -o loop "$EFI_IMAGE" "$MOUNT_POINT/boot/efi"
fi

# If GRUB is present and fussy about device.map, you can keep or drop this — harmless if absent
if [ -d "$MOUNT_POINT/boot/grub" ]; then
  printf "(hd0) %s\n" "loopback" | sudo tee "$MOUNT_POINT/boot/grub/device.map" >/dev/null || true
fi

# Apply overlay flow, honouring DEBUG modes
if [ "$DEBUG" = "chroot" ]; then
  echo "Applying stack: $STACK"
  python3 /project/overlay.py apply \
    --overlay-dirs "/tmp/work/input" \
    --mount-point "$MOUNT_POINT" \
    --resources "$RESOURCES" \
    --stack="$STACK"
  echo "Entering chroot (debug mode). Type 'exit' to resume..."
  sudo chroot "$MOUNT_POINT" /bin/bash
elif [ "$DEBUG" = "true" ]; then
  echo "Debugging enabled. Mounted at $MOUNT_POINT"
  echo "To call the overlay, run: python3 /project/overlay.py apply --overlay-dirs /tmp/work/input --mount-point $MOUNT_POINT --resources $RESOURCES --stack $STACK"
  /bin/bash
else
  echo "Applying stack: $STACK"
  python3 /project/overlay.py apply \
    --overlay-dirs "/tmp/work/input" \
    --mount-point "$MOUNT_POINT" \
    --resources "$RESOURCES" \
    --stack="$STACK"
fi

# Cleanup
[ -f "$MOUNT_POINT/boot/grub/device.map" ] && sudo rm -f "$MOUNT_POINT/boot/grub/device.map"
echo "==> Unmounting ..."
cleanup_mounts

echo "Done."
exit 0