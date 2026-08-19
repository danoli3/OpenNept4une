#!/usr/bin/env bash
# Point the image's default Rockchip DTB at the v1.x or v2.0 board file.
# The two release images are the same userspace; only the default DTB differs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0 <image.img> <v1x|v20>

Copies the matching DTB from this repo over:
  /boot/dtb/rockchip/rk3328-roc-cc.dtb

v1x = Neptune 4 / 4 Pro (ZNP-K1 V1.x)
v20 = Neptune 4 Plus / Max (ZNP-K1 V2.0)
EOF
}

[[ $# -eq 2 ]] || { usage; exit 1; }
[[ "$1" != "-h" && "$1" != "--help" ]] || { usage; exit 0; }

require_linux
require_root
need_cmd losetup
need_cmd mount

IMG="$1"
VARIANT="$2"
[[ -f "$IMG" ]] || die "Not a file: $IMG"

case "$VARIANT" in
  v1x|v1.x|V1.x)
    SRC_DTB="${REPO_ROOT}/dtb/n4-n4pro-v1.1/rk3328-znp-v1x.dtb"
    ;;
  v20|v2.0|V2.0|v2x)
    SRC_DTB="${REPO_ROOT}/dtb/n4plus-n4max-v1.1-2.0/rk3328-znp-v2x.dtb"
    ;;
  *)
    die "variant must be v1x or v20"
    ;;
esac
if [[ ! -f "$SRC_DTB" ]]; then
  src_dts="${SRC_DTB%.dtb}.dts"
  if [[ -f "$src_dts" ]] && command -v dtc >/dev/null 2>&1; then
    SRC_DTB="$(mktemp "${TMPDIR:-/tmp}/on4-dtb.XXXXXX.dtb")"
    ok "Compiling ${src_dts}"
    dtc -I dts -O dtb -o "$SRC_DTB" "$src_dts"
  fi
fi
[[ -f "$SRC_DTB" ]] || die "DTB not in this checkout (and could not compile a .dts)"

LOOP=""
MNT=""
cleanup() {
  if [[ -n "$MNT" ]]; then
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
  fi
  if [[ -n "$LOOP" ]]; then
    losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

LOOP="$(losetup -f --show -P "$IMG")"
partprobe "$LOOP" || true
MNT="$(mktemp -d)"

# Prefer a mounted /boot, else the root fs /boot directory.
root_part=""
boot_part=""
best=0
for p in "${LOOP}"p*; do
  [[ -b "$p" ]] || continue
  fstype="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
  case "$fstype" in
    vfat) boot_part="$p" ;;
    ext4)
      sz="$(blockdev --getsize64 "$p")"
      if (( sz > best )); then
        root_part="$p"
        best="$sz"
      fi
      ;;
  esac
done
[[ -n "$root_part" ]] || die "No ext4 root"

if [[ -n "$boot_part" ]]; then
  mount "$boot_part" "$MNT"
  DEST="${MNT}/dtb/rockchip/rk3328-roc-cc.dtb"
  if [[ ! -d "${MNT}/dtb/rockchip" ]]; then
    umount "$MNT"
    mount "$root_part" "$MNT"
    DEST="${MNT}/boot/dtb/rockchip/rk3328-roc-cc.dtb"
  fi
else
  mount "$root_part" "$MNT"
  DEST="${MNT}/boot/dtb/rockchip/rk3328-roc-cc.dtb"
fi

[[ -d "$(dirname "$DEST")" ]] || die "No dtb/rockchip directory in image"
cp -f "$SRC_DTB" "$DEST"
sync
ok "Installed $(basename "$SRC_DTB") as ${DEST#${MNT}}"
