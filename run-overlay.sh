#!/bin/bash
set -euo pipefail

if [ "${DEBUG:-}" = "true" ]; then
  set -x
fi

usage() {
  echo "Usage: $0 -f <filesystem> -s <stack> -r <resources> -d <debug> [-e <env_list>] [-E <efi_image>] [-O <overlay_root>]"
  echo "  -f <filesystem>: Path to the EXT4 system/root filesystem image to modify (raw EXT4 or Android sparse)."
  echo "  -r <resources> : Path to extra resources directory."
  echo "  -s <stack>     : Stack name of the overlay stack to apply."
  echo "  -d <debug>     : true | false | chroot — Debug mode (optional)."
  echo "  -e <env_list>  : Comma-separated list of KEY=VALUE pairs to export (optional)."
  echo "  -E <efi_image> : OPTIONAL path to a FAT EFI image to mount at /boot/efi (24.04 flow)."
  echo "  -O <overlay_root>: OPTIONAL path to overlay root (parent dir of 'overlays/' and 'stacks/')."
  echo "                     Defaults to /tmp/work/input."
  exit 1
}

# --- Parse args ---------------------------------------------------------------
DEBUG="false"
FILESYSTEM=""
RESOURCES=""
STACK=""
EFI_IMG=""
OVERLAY_ROOT="/tmp/work/input"   # NEW: default for Docker flow
ENV_LIST="${ENV_LIST:-}"

while getopts ":f:r:d:s:e:E:O:" opt; do
  case $opt in
    f) FILESYSTEM="$OPTARG" ;;
    r) RESOURCES="$OPTARG" ;;
    d) DEBUG="$OPTARG" ;;
    s) STACK="$OPTARG" ;;
    e) ENV_LIST="$OPTARG" ;;
    E) EFI_IMG="$OPTARG" ;;
    O) OVERLAY_ROOT="$OPTARG" ;;  # NEW
    *) usage ;;
  esac
done

# ENV_LIST contains "KEY=VAL,KEY2=VAL2,..."
if [ -n "${ENV_LIST:-}" ]; then
  OLDIFS="$IFS"; IFS=',' 
  for kv in $ENV_LIST; do 
    kv="$(echo "$kv" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"   # trim
    [ -n "$kv" ] && export "$kv"
  done
  IFS="$OLDIFS"
fi

[ -n "${FILESYSTEM:-}" ] && [ -n "${STACK:-}" ] && [ -n "${RESOURCES:-}" ] || usage
[ -f "$FILESYSTEM" ] || { echo "Error: Filesystem '$FILESYSTEM' does not exist." >&2; exit 1; }
if [ -n "$EFI_IMG" ] && [ ! -f "$EFI_IMG" ]; then
  echo "Error: EFI image '$EFI_IMG' does not exist." >&2
  ls -al "$EFI_IMG" || true
  exit 1
fi

# resolve overlay.py relative to this script (works in/out of Docker)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_CLI="${OVERLAY_CLI:-$SCRIPT_DIR/overlay.py}"
if [ ! -f "$OVERLAY_CLI" ]; then
  # Fallback to CWD if someone runs from repo root
  if [ -f "./overlay.py" ]; then
    OVERLAY_CLI="./overlay.py"
  else
    echo "Error: overlay.py not found at '$OVERLAY_CLI' or './overlay.py'." >&2
    exit 1
  fi
fi

# Optional sanity: ensure OVERLAY_ROOT has overlays/ and stacks/ (warn only)
if [ ! -d "$OVERLAY_ROOT/overlays" ] || [ ! -d "$OVERLAY_ROOT/stacks" ]; then
  echo "Warning: OVERLAY_ROOT ($OVERLAY_ROOT) may be missing 'overlays/' or 'stacks/'." >&2
fi

# --- Safe defaults / PATH -----------------------------------------------------
# Use a fast, container-local scratch by default (overridable)
TMP_DIR="${TMP_DIR:-/var/tmp/tachyon_overlay}"   # was /tmp/work (bind mount; slow on Docker for Mac)
MOUNT_POINT="/mnt/tachyon"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
mkdir -p "$TMP_DIR"

# --- Print args ---------------------------------------------------------------
echo "==> process-release"
echo "    FILESYSTEM: $FILESYSTEM"
echo "    RESOURCES : $RESOURCES"
echo "    STACK     : $STACK"
echo "    DEBUG     : ${DEBUG:-auto}"
echo "    ENV_LIST  : ${ENV_LIST:-}"
echo "    EFI_IMG   : ${EFI_IMG:-<none>}"
echo "    OVERLAYS  : ${OVERLAY_ROOT}"

# --- Helpers ------------------------------------------------------------------
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

# --- Flow selector: ONLY by presence of EFI image -----------------------------
ftype="$(file -b "$FILESYSTEM" || true)"
IS_SPARSE=false
if echo "$ftype" | grep -qi 'Android sparse image'; then
  IS_SPARSE=true
fi

if [ -n "$EFI_IMG" ]; then
  echo "    TYPE: $ftype"
  echo "    FLOW: with-efi (partitioned loopdev)"
else
  echo "    TYPE: $ftype"
  echo "    FLOW: $([ "$IS_SPARSE" = true ] && echo 'sparse->raw (no-efi)' || echo 'raw ext4 (no-efi)')"
fi

# --- WITH EFI: CI-style GPT loopdev path -------------------------------------
if [ -n "$EFI_IMG" ]; then
  sudo mkdir -p "$MOUNT_POINT" "$MOUNT_POINT/boot/efi"

  # If the provided rootfs is Android sparse, unsparse to <file>.raw first.
  SPARSE_SOURCE=false
  raw_ext4="$FILESYSTEM"
  if [ "$IS_SPARSE" = true ]; then
    SPARSE_SOURCE=true
    raw_ext4="${FILESYSTEM}.raw"
    echo "==> Unsparsing Android sparse rootfs to $raw_ext4 ..."
    make docker-unsparse-image SYSTEM_IMAGE="$FILESYSTEM" SYSTEM_OUTPUT="$raw_ext4"
  fi

  # Create a temporary partitioned container image; p1 sized to the ext4.
  part_img="${TMP_DIR}/partitioned-$$.img"
  part_size=$(stat -c%s "$raw_ext4")
  img_size=$((part_size + 10 * 1024 * 1024)) # +10MiB slack
  echo "==> Creating temp GPT image: $part_img (size=$img_size; p1=$part_size)"
  truncate -s "$img_size" "$part_img"

  echo "==> Setting up loop device (4K alignment) ..."
  LOOPDEV="$(sudo losetup -b 4096 -f --show "$part_img")"
  echo "    LOOPDEV: $LOOPDEV"

  echo "==> Partitioning GPT (single Linux fs 'system_a') ..."
  sudo sgdisk -Z "$LOOPDEV"
  sudo sgdisk -a 2 -n 0:0:+$((part_size / 4096)) -t 0:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 0:"system_a" "$LOOPDEV"
  sudo partx -a "$LOOPDEV"
  command -v udevadm >/dev/null 2>&1 && sudo udevadm settle || true
  sleep 1

  PART_ROOT="${LOOPDEV}p1"
  [ -e "$PART_ROOT" ] || { echo "ERROR: missing ${LOOPDEV}p1"; exit 1; }

  echo "==> dd rootfs -> ${PART_ROOT} ..."
  sudo dd if="$raw_ext4" of="${PART_ROOT}" bs=8M iflag=fullblock oflag=direct status=progress
  sync

  echo "==> Mounting root and EFI ..."
  sudo mount "${PART_ROOT}" "$MOUNT_POINT"
  mount_binds
  sudo mkdir -p "$MOUNT_POINT/boot/efi"
  sudo mount -o loop "$EFI_IMG" "$MOUNT_POINT/boot/efi"

  # GRUB device.map
  if [ -d "$MOUNT_POINT/boot/grub" ]; then
    printf "(hd0) %s\n(hd1) %sp1\n" "$LOOPDEV" "$LOOPDEV" | sudo tee "$MOUNT_POINT/boot/grub/device.map" >/dev/null || true
  fi

  # --- Run overlay -----------------------------------------------------------
  if [ "$DEBUG" = "chroot" ]; then
    echo "Applying stack: $STACK"
    python3 "$OVERLAY_CLI" apply --overlay-dirs "$OVERLAY_ROOT" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
    echo "Entering chroot (debug mode). Type 'exit' to resume..."
    sudo chroot "$MOUNT_POINT" /bin/bash
  elif [ "$DEBUG" = "true" ]; then
    echo "Debugging enabled. Mounted at $MOUNT_POINT"
    echo "To call the overlay, run: python3 "$OVERLAY_CLI" apply --mount-point $MOUNT_POINT --resources $RESOURCES --stack $STACK"
    /bin/bash
  else
    echo "Applying stack: $STACK"
    python3 "$OVERLAY_CLI" apply --overlay-dirs "$OVERLAY_ROOT" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
  fi

  # Clean device.map, unmount, persist back, cleanup
  [ -f "$MOUNT_POINT/boot/grub/device.map" ] && sudo rm -f "$MOUNT_POINT/boot/grub/device.map"

  echo "==> Unmounting root & EFI ..."
  sudo umount "$MOUNT_POINT/boot/efi" 2>/dev/null || true
  sudo umount "$MOUNT_POINT/dev/pts" 2>/dev/null || true
  sudo umount "$MOUNT_POINT/run"      2>/dev/null || true
  sudo umount "$MOUNT_POINT/sys"      2>/dev/null || true
  sudo umount "$MOUNT_POINT/proc"     2>/dev/null || true
  sudo umount "$MOUNT_POINT/dev"      2>/dev/null || true
  sudo umount "$MOUNT_POINT"          2>/dev/null || true
  sync

  echo "==> dd ${PART_ROOT} -> $raw_ext4 (persist changes) ..."
  sudo dd if="${PART_ROOT}" of="$raw_ext4" bs=8M iflag=fullblock oflag=direct status=progress
  sync

  echo "==> Detaching loop & cleaning up ..."
  sudo partx -d "$LOOPDEV" 2>/dev/null || true
  sudo kpartx -d "$LOOPDEV" 2>/dev/null || true
  sudo losetup -d "$LOOPDEV" 2>/dev/null || true
  unset LOOPDEV
  rm -f "$part_img"

  # If source was sparse, re-sparsify back into the original path
  if [ "$SPARSE_SOURCE" = true ]; then
    echo "==> Re-sparsifying back into $FILESYSTEM ..."
    make docker-sparse-image SYSTEM_IMAGE="$FILESYSTEM"
  fi

  echo "Done."
  exit 0
fi

# --- WITHOUT EFI: simple overlay path ----------------------------------------
# Two sub-cases: Android sparse (unsparse->mount->overlay->re-sparse) or raw ext4.
if [ "$IS_SPARSE" = true ]; then
  RAW="${FILESYSTEM}.raw"
  echo "==> Unsparsing to $RAW ..."
  make docker-unsparse-image SYSTEM_IMAGE="$FILESYSTEM" SYSTEM_OUTPUT="$RAW"

  echo "==> Mounting raw filesystem ..."
  sudo mkdir -p "$MOUNT_POINT"
  sudo mount -o loop "$RAW" "$MOUNT_POINT"
  mount_binds

  # Optional, harmless for GRUB if present
  if [ -d "$MOUNT_POINT/boot/grub" ]; then
    printf "(hd0) %s\n(hd1) %s\n" "loopback" "loopback" | sudo tee "$MOUNT_POINT/boot/grub/device.map" >/dev/null || true
  fi

  if [ "$DEBUG" = "chroot" ]; then
    echo "Applying stack: $STACK"
    python3 "$OVERLAY_CLI" apply --overlay-dirs "$OVERLAY_ROOT" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
    echo "Entering chroot (debug mode). Type 'exit' to resume..."
    sudo chroot "$MOUNT_POINT" /bin/bash
  elif [ "$DEBUG" = "true" ]; then
    echo "Debugging enabled. Mounted at $MOUNT_POINT"
    echo "To call the overlay, run: python3 "$OVERLAY_CLI" apply --mount-point $MOUNT_POINT --resources $RESOURCES --stack $STACK"
    /bin/bash
  else
    echo "Applying stack: $STACK"
    python3 "$OVERLAY_CLI" apply --overlay-dirs "$OVERLAY_ROOT" --mount-point "$MOUNT_POINT" --resources "$RESOURCES" --stack="$STACK"
  fi

  [ -f "$MOUNT_POINT/boot/grub/device.map" ] && sudo rm -f "$MOUNT_POINT/boot/grub/device.map"
  echo "==> Unmounting ..."
  cleanup_mounts

  echo "==> Re-sparsifying back into $FILESYSTEM ..."
  make docker-sparse-image SYSTEM_IMAGE="$FILESYSTEM"

  echo "Done."
  exit 0
fi

# Raw ext4, no EFI
echo "==> Mounting ext4 filesystem via loop (no-efi) ..."
sudo mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$FILESYSTEM" "$MOUNT_POINT"
mount_binds

# If GRUB present, a minimal device.map can help; harmless if absent
if [ -d "$MOUNT_POINT/boot/grub" ]; then
  printf "(hd0) %s\n" "loopback" | sudo tee "$MOUNT_POINT/boot/grub/device.map" >/dev/null || true
fi

# Apply overlay, honouring DEBUG modes
if [ "$DEBUG" = "chroot" ]; then
  echo "Applying stack: $STACK"
  python3 "$OVERLAY_CLI" apply \
    --overlay-dirs "$OVERLAY_ROOT" \
    --mount-point "$MOUNT_POINT" \
    --resources "$RESOURCES" \
    --stack="$STACK"
  echo "Entering chroot (debug mode). Type 'exit' to resume..."
  sudo chroot "$MOUNT_POINT" /bin/bash
elif [ "$DEBUG" = "true" ]; then
  echo "Debugging enabled. Mounted at $MOUNT_POINT"
  echo "To call the overlay, run: python3 "$OVERLAY_CLI" apply --overlay-dirs $OVERLAY_ROOT --mount-point $MOUNT_POINT --resources $RESOURCES --stack $STACK"
  /bin/bash
else
  echo "Applying stack: $STACK"
  python3 "$OVERLAY_CLI" apply \
    --overlay-dirs "$OVERLAY_ROOT" \
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