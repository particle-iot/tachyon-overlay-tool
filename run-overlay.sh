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
VENDOR_IMG=""
ENV_LIST="${ENV_LIST:-}"

while getopts ":f:r:d:s:e:E:O:V:" opt; do
  case $opt in
    f) FILESYSTEM="$OPTARG" ;;
    r) RESOURCES="$OPTARG" ;;
    d) DEBUG="$OPTARG" ;;
    s) STACK="$OPTARG" ;;
    e) ENV_LIST="$OPTARG" ;;
    E) EFI_IMG="$OPTARG" ;;
    O) OVERLAY_ROOT="$OPTARG" ;;  # NEW
    V) VENDOR_IMG="$OPTARG" ;;
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

# Surface ENV_* config values (plain build values, not packages) so CI logs confirm
# they were received and forwarded into the overlay run.
for ev in $(compgen -e | grep '^ENV_' || true); do
  echo "[run-overlay] ENV value received: ${ev}=${!ev}"
done

[ -n "${FILESYSTEM:-}" ] && [ -n "${STACK:-}" ] && [ -n "${RESOURCES:-}" ] || usage
[ -f "$FILESYSTEM" ] || { echo "Error: Filesystem '$FILESYSTEM' does not exist." >&2; exit 1; }
if [ -n "$EFI_IMG" ] && [ ! -f "$EFI_IMG" ]; then
  echo "Error: EFI image '$EFI_IMG' does not exist." >&2
  ls -al "$EFI_IMG" || true
  exit 1
fi

if [ -n "$VENDOR_IMG" ] && [ ! -f "$VENDOR_IMG" ]; then
  echo "Error: vendor image '$VENDOR_IMG' does not exist." >&2
  ls -al "$VENDOR_IMG" || true
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
echo "    VENDOR_IMG: ${VENDOR_IMG:-<none>}"
echo "    OVERLAYS  : ${OVERLAY_ROOT}"

# --- Helpers ------------------------------------------------------------------
cleanup_mounts() {
  set +e
  sudo umount "$MOUNT_POINT/boot/efi" 2>/dev/null || true
  sudo umount "$MOUNT_POINT/vendor" 2>/dev/null || true
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

# Is $1 a mount point? Reads /proc/self/mounts directly so this needs no util-linux tooling
# (the build container is minimal). Paths with spaces would need \040 unescaping; the overlay
# mount points never contain any.
is_mounted() {
  local p
  p="$(readlink -f "$1" 2>/dev/null || echo "$1")"
  awk -v t="$p" '$2 == t { found = 1 } END { exit !found }' /proc/self/mounts
}

# Unmount everything under $1 and VERIFY it, returning non-zero if we cannot.
#
# Both overlay flows persist their changes by copying the filesystem back out -- the EFI flow
# dd's the loop partition over the ext4 file, the sparse flow re-sparsifies it. Doing either
# while the filesystem is still mounted yields an image that looks perfect and is quietly
# wrong: ext4 commits its journal every few seconds, so e2fsck replays it and reports "clean",
# but any write still sitting in the page cache is simply gone. The newest writes are the ones
# lost. In a real 1.2.8 build that meant the last dpkg transaction's 9 files were never renamed
# off their .dpkg-new names -- while dpkg's status file, already flushed, recorded the package
# as installed -- and a just-created /etc/particle/distro_versions.json held another package's
# control blob instead of its JSON. Nothing downstream catches it, because the filesystem is
# internally consistent; it shipped, and the device then failed board detection.
#
# So a failed umount here MUST abort the build. The previous code ran every umount as
# `2>/dev/null || true`, which is precisely what made that failure invisible.
unmount_all_strictly() {
  local mp sub i
  mp="$(readlink -f "$1" 2>/dev/null || echo "$1")"

  # Inner mounts first; /dev/pts must go before /dev or it holds it busy.
  for sub in vendor boot/efi dev/pts run sys proc dev; do
    unmount_one "$mp/$sub" 6 || return 1
  done
  unmount_one "$mp" 10 || return 1
  sync
  return 0
}

# Unmount $1 until it is genuinely not a mount point, giving up after $2 attempts.
#
# Loops rather than unmounting once: mounts can be STACKED on one directory (a retried build
# step, a bind that got applied twice), and each umount peels off only the top layer. A single
# umount can therefore "succeed" while the path is still mounted -- which is the same hazard
# this whole function exists to prevent.
unmount_one() {
  local target attempts limit
  target="$1"; limit="$2"; attempts=0
  while is_mounted "$target"; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt "$limit" ]; then
      echo "ERROR: $target is still mounted after $limit umount attempts." >&2
      command -v fuser >/dev/null 2>&1 && sudo fuser -vm "$target" >&2 2>&1 || true
      return 1
    fi
    # A successful umount may have only removed one layer of a stack, so re-test rather
    # than assuming we are done.
    if sudo umount "$target"; then continue; fi
    echo "WARN: umount $target is busy (attempt $attempts/$limit); retrying in 2s"
    sleep 2
  done
  return 0
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

  if [ -n "$VENDOR_IMG" ]; then
    sudo mkdir -p "$MOUNT_POINT/vendor"
    sudo mount -o loop "$VENDOR_IMG" "$MOUNT_POINT/vendor"
  fi

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
  if ! unmount_all_strictly "$MOUNT_POINT"; then
    echo "ERROR: refusing to dd a still-mounted filesystem back over $raw_ext4 -- the image" >&2
    echo "       would pass e2fsck while silently missing its most recent writes." >&2
    exit 1
  fi

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

  if [ -n "$VENDOR_IMG" ]; then
    sudo mkdir -p "$MOUNT_POINT/vendor"
    sudo mount -o loop "$VENDOR_IMG" "$MOUNT_POINT/vendor"
  fi

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
  if ! unmount_all_strictly "$MOUNT_POINT"; then
    echo "ERROR: refusing to re-sparsify a still-mounted filesystem -- see above." >&2
    exit 1
  fi
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

if [ -n "$VENDOR_IMG" ]; then
  sudo mkdir -p "$MOUNT_POINT/vendor"
  sudo mount -o loop "$VENDOR_IMG" "$MOUNT_POINT/vendor"
fi

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

# Cleanup. Unmounting the loop-mounted image IS how changes land here, so it must be verified.
[ -f "$MOUNT_POINT/boot/grub/device.map" ] && sudo rm -f "$MOUNT_POINT/boot/grub/device.map"
echo "==> Unmounting ..."
if ! unmount_all_strictly "$MOUNT_POINT"; then
  echo "ERROR: $FILESYSTEM may not have received all overlay writes -- see above." >&2
  exit 1
fi
cleanup_mounts

echo "Done."
exit 0