#!/usr/bin/env bash
# Dump (optional), shrink rootfs, cap image at MAX_IMAGE_MIB, compress xz.
#
# Usage:
#   sudo ./img-build/03-shrink-pack.sh /path/to/image.img
#   sudo ./img-build/03-shrink-pack.sh /path/to/image.img.xz
#   sudo ./img-build/03-shrink-pack.sh /dev/sdX
#
# Never shrinks a block device in place. Devices are dumped first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0 <image.img|image.img.xz|/dev/sdX> [output-prefix]

Shrink the root ext4 partition, cap the .img at ${MAX_IMAGE_MIB} MiB
(so it fits stock ~7.2 GiB eMMC), and write an xz next to it.

Env:
  MAX_IMAGE_MIB   cap for the uncompressed image (default ${MAX_IMAGE_MIB})
  SLACK_MIB       free space left in the fs after shrink (default ${SLACK_MIB})
  WORK_DIR        dump/decompress workspace (default ${WORK_DIR})
  XZ_ARGS         passed to xz (default ${XZ_ARGS})
  KEEP_RAW=1      keep the uncompressed .img after xz
EOF
}

[[ $# -ge 1 ]] || { usage; exit 1; }
[[ "${1}" != "-h" && "${1}" != "--help" ]] || { usage; exit 0; }

require_linux
require_root
need_cmd losetup
need_cmd sfdisk
need_cmd e2fsck
need_cmd resize2fs
need_cmd tune2fs
need_cmd xz
need_cmd blkid

SRC="$1"
OUT_PREFIX="${2:-}"
mkdir -p "$WORK_DIR"
WORKDIR="$(mktemp -d "${WORK_DIR}/shrink.XXXXXX")"
LOOP=""
MOUNTED=""

cleanup() {
  if [[ -n "$MOUNTED" ]]; then
    umount "$MOUNTED" 2>/dev/null || umount -l "$MOUNTED" 2>/dev/null || true
  fi
  if [[ -n "$LOOP" ]]; then
    losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

ok "Workspace ${WORKDIR}"

if [[ -b "$SRC" ]]; then
  RAW="${WORKDIR}/dumped.img"
  SRC_BYTES="$(bytes_of "$SRC")"
  ok "Dumping ${SRC} ($(mib "$SRC_BYTES") MiB) — not shrinking the device in place"
  dd if="$SRC" of="$RAW" bs=4M status=progress conv=fsync
  IMG="$RAW"
elif [[ -f "$SRC" ]]; then
  case "$SRC" in
    *.xz)
      RAW="${WORKDIR}/decompressed.img"
      ok "Decompressing ${SRC}"
      xz -dc -T0 "$SRC" > "$RAW"
      IMG="$RAW"
      ;;
    *)
      IMG="${WORKDIR}/work.img"
      ok "Copying ${SRC} to workspace"
      cp -f "$SRC" "$IMG"
      ;;
  esac
else
  die "Not a file or block device: $SRC"
fi

[[ -f "$IMG" ]] || die "No working image"

LOOP="$(losetup -f --show -P "$IMG")"
ok "Loop ${LOOP}"
# Wait for partition nodes
for _ in 1 2 3 4 5; do
  [[ -b "${LOOP}p1" || -b "${LOOP}p2" ]] && break
  sleep 0.2
  partprobe "$LOOP" || true
done

find_root_part() {
  local p fstype best="" best_size=0 sz
  for p in "${LOOP}"p*; do
    [[ -b "$p" ]] || continue
    fstype="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
    [[ "$fstype" == "ext4" ]] || continue
    sz="$(blockdev --getsize64 "$p")"
    if (( sz > best_size )); then
      best="$p"
      best_size="$sz"
    fi
  done
  [[ -n "$best" ]] || die "No ext4 root partition on ${LOOP}"
  echo "$best"
}

PART="$(find_root_part)"
ok "Root partition ${PART}"

e2fsck -f -y "$PART" || true

BLOCK_SIZE="$(tune2fs -l "$PART" | awk -F: '/Block size/ {gsub(/ /,"",$2); print $2}')"
BLOCK_COUNT="$(tune2fs -l "$PART" | awk -F: '/Block count/ {gsub(/ /,"",$2); print $2}')"
[[ -n "$BLOCK_SIZE" && -n "$BLOCK_COUNT" ]] || die "Could not read ext4 geometry"

ok "Current filesystem $(mib $((BLOCK_SIZE * BLOCK_COUNT))) MiB — shrinking to minimum"
resize2fs -M "$PART"

BLOCK_COUNT="$(tune2fs -l "$PART" | awk -F: '/Block count/ {gsub(/ /,"",$2); print $2}')"
MIN_BYTES=$((BLOCK_COUNT * BLOCK_SIZE))
ok "Minimum filesystem $(mib "$MIN_BYTES") MiB"

# Partition start of the root partition (512-byte sectors)
PARTNUM="${PART##*p}"
SFDISK_DUMP="$(sfdisk -d "$LOOP")"
PART_START="$(printf '%s\n' "$SFDISK_DUMP" | awk -v part="${LOOP}p${PARTNUM}" '
  $1 == part {
    for (i = 1; i <= NF; i++) if ($i ~ /^start=/) { gsub(/[^0-9]/, "", $i); print $i; exit }
  }
')"
[[ -n "$PART_START" ]] || die "Could not parse start sector for partition ${PARTNUM}"

# Image must cover everything before root + the new root size.
SLACK_BYTES=$((SLACK_MIB * 1024 * 1024))
WANT_FS_BYTES=$((MIN_BYTES + SLACK_BYTES))
# align filesystem grow to 4 MiB
ALIGN=$((4 * 1024 * 1024))
WANT_FS_BYTES=$(( (WANT_FS_BYTES + ALIGN - 1) / ALIGN * ALIGN ))

PREFIX_BYTES=$((PART_START * 512))
WANT_IMG_BYTES=$((PREFIX_BYTES + WANT_FS_BYTES + 1024 * 1024))
MAX_BYTES=$((MAX_IMAGE_MIB * 1024 * 1024))

if (( WANT_IMG_BYTES > MAX_BYTES )); then
  ROOM=$((MAX_BYTES - PREFIX_BYTES - 1024 * 1024))
  if (( ROOM <= MIN_BYTES )); then
    echo
    echo "Root filesystem minimum is $(mib "$MIN_BYTES") MiB plus partition prefix $(mib "$PREFIX_BYTES") MiB."
    echo "That cannot fit in MAX_IMAGE_MIB=${MAX_IMAGE_MIB}."
    echo "Mount the image and inspect with: sudo du -xh --max-depth=1 /mnt"
    die "used space exceeds ${MAX_IMAGE_MIB} MiB cap"
  fi
  warn "Clamping filesystem to stay under ${MAX_IMAGE_MIB} MiB"
  WANT_FS_BYTES=$ROOM
  WANT_IMG_BYTES=$((PREFIX_BYTES + WANT_FS_BYTES + 1024 * 1024))
fi

WANT_FS_BLOCKS=$((WANT_FS_BYTES / BLOCK_SIZE))
if (( WANT_FS_BYTES > MIN_BYTES )); then
  ok "Growing filesystem to $(mib "$WANT_FS_BYTES") MiB (min + ${SLACK_MIB} MiB slack, capped)"
  resize2fs "$PART" "$WANT_FS_BLOCKS"
fi

# Shrink the partition to the filesystem (sectors, 2048-aligned)
FS_BYTES_NOW=$((WANT_FS_BLOCKS * BLOCK_SIZE))
NEW_PART_SECTORS=$(( (FS_BYTES_NOW + 511) / 512 ))
# align partition size up to 2048 sectors (1 MiB)
NEW_PART_SECTORS=$(( (NEW_PART_SECTORS + 2047) / 2048 * 2048 ))

ok "Resizing partition ${PARTNUM} to ${NEW_PART_SECTORS} sectors"
echo ",${NEW_PART_SECTORS}" | sfdisk --no-reread -N "$PARTNUM" "$LOOP"
partprobe "$LOOP" || true
sleep 0.5
e2fsck -f -y "$PART" || true

# Highest used sector across the table
END_SECTOR="$(sfdisk -d "$LOOP" | awk '
  /start=/ {
    start = 0; size = 0
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^start=/) { v = $i; gsub(/[^0-9]/, "", v); start = v + 0 }
      if ($i ~ /^size=/)  { v = $i; gsub(/[^0-9]/, "", v); size  = v + 0 }
    }
    end = start + size
    if (end > max) max = end
  }
  END { print max + 0 }
')"
[[ -n "$END_SECTOR" && "$END_SECTOR" -gt 0 ]] || die "Could not compute image end sector"

# +1 MiB tail
NEW_IMG_BYTES=$(( (END_SECTOR + 2048) * 512 ))
if (( NEW_IMG_BYTES > MAX_BYTES )); then
  die "Shrunk image would still be $(mib "$NEW_IMG_BYTES") MiB > MAX_IMAGE_MIB=${MAX_IMAGE_MIB}"
fi

losetup -d "$LOOP"
LOOP=""

ok "Truncating image to $(mib "$NEW_IMG_BYTES") MiB"
truncate -s "$NEW_IMG_BYTES" "$IMG"

# Name outputs
if [[ -z "$OUT_PREFIX" ]]; then
  if [[ -f "$SRC" && "$SRC" != *.xz ]]; then
    OUT_PREFIX="${SRC%.img}"
    OUT_PREFIX="${OUT_PREFIX%.IMG}"
  else
    stamp="$(date +%Y%m%d)"
    branch="$(repo_branch)"
    OUT_PREFIX="${WORK_DIR}/OpenNept4une-${branch}-${stamp}"
  fi
fi
OUT_IMG="${OUT_PREFIX}.img"
OUT_XZ="${OUT_IMG}.xz"

if [[ "$IMG" != "$OUT_IMG" ]]; then
  mkdir -p "$(dirname "$OUT_IMG")"
  cp -f "$IMG" "$OUT_IMG"
fi

ok "Compressing ${OUT_XZ}"
# shellcheck disable=SC2086
xz -f ${XZ_ARGS} -k -c "$OUT_IMG" > "$OUT_XZ"

IMG_BYTES="$(bytes_of "$OUT_IMG")"
XZ_BYTES="$(bytes_of "$OUT_XZ")"
FIT="NO"
if (( IMG_BYTES <= MAX_BYTES )); then
  FIT="YES"
fi

echo
echo "======== image size ========"
echo "uncompressed: $(mib "$IMG_BYTES") MiB ($(gib "$IMG_BYTES") GiB)  ${OUT_IMG}"
echo "xz:           $(mib "$XZ_BYTES") MiB                             ${OUT_XZ}"
echo "cap:          ${MAX_IMAGE_MIB} MiB"
echo "fits stock 8GB / 7.2 GiB eMMC: ${FIT}"
echo "v0.1.7 was 7456 MiB uncompressed and overflowed some chips."
echo "============================"

if [[ "${KEEP_RAW:-0}" != "1" && "$OUT_IMG" == "${WORKDIR}"* ]]; then
  rm -f "$OUT_IMG"
fi
ok "Done"
