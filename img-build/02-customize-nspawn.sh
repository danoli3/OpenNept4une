#!/usr/bin/env bash
# Mount an Armbian .img and run image-bake-install.sh inside it.
# Same-arch (aarch64 host + aarch64 image) is the supported path.
# Cross-arch needs qemu-user-static.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0 <armbian.img|armbian.img.xz>

Mounts the image, copies this OpenNept4une checkout to /home/${TARGET_USER}/OpenNept4une,
and runs img-config/image-bake-install.sh in a chroot or systemd-nspawn.

Prefer baking on a booted ZNP-K1 if nspawn/qemu misbehave.
EOF
}

[[ $# -ge 1 ]] || { usage; exit 1; }
[[ "$1" != "-h" && "$1" != "--help" ]] || { usage; exit 0; }

require_linux
require_root
need_cmd losetup
need_cmd mount
need_cmd rsync
need_cmd blkid

SRC="$1"
mkdir -p "$WORK_DIR"
WORKDIR="$(mktemp -d "${WORK_DIR}/nspawn.XXXXXX")"
LOOP=""
ROOT_MNT="${WORKDIR}/root"
BOOT_MNT=""

cleanup() {
  if [[ -n "${BOOT_MNT}" ]]; then
    umount "$BOOT_MNT" 2>/dev/null || umount -l "$BOOT_MNT" 2>/dev/null || true
  fi
  for d in proc sys dev/pts dev run; do
    umount "${ROOT_MNT}/${d}" 2>/dev/null || umount -l "${ROOT_MNT}/${d}" 2>/dev/null || true
  done
  if mountpoint -q "$ROOT_MNT" 2>/dev/null; then
    umount "$ROOT_MNT" 2>/dev/null || umount -l "$ROOT_MNT" 2>/dev/null || true
  fi
  if [[ -n "$LOOP" ]]; then
    losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$SRC" == *.xz ]]; then
  IMG="${WORKDIR}/base.img"
  ok "Decompressing ${SRC}"
  xz -dc -T0 "$SRC" > "$IMG"
elif [[ -f "$SRC" ]]; then
  # Work on a copy so a failed customize does not destroy the input
  IMG="${WORKDIR}/work.img"
  ok "Copying ${SRC}"
  cp -f "$SRC" "$IMG"
else
  die "Not an image file: $SRC"
fi

LOOP="$(losetup -f --show -P "$IMG")"
ok "Loop ${LOOP}"
for _ in 1 2 3 4 5; do
  [[ -b "${LOOP}p1" || -b "${LOOP}p2" ]] && break
  sleep 0.2
  partprobe "$LOOP" || true
done

find_part_by_type() {
  local want="$1" p fstype
  for p in "${LOOP}"p*; do
    [[ -b "$p" ]] || continue
    fstype="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
    if [[ "$fstype" == "$want" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# Largest ext4 is root. A smaller vfat/ext4 is /boot if present.
ROOT_PART=""
BOOT_PART=""
best=0
for p in "${LOOP}"p*; do
  [[ -b "$p" ]] || continue
  fstype="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
  [[ "$fstype" == "ext4" ]] || continue
  sz="$(blockdev --getsize64 "$p")"
  if (( sz > best )); then
    if [[ -n "$ROOT_PART" ]]; then
      BOOT_PART="$ROOT_PART"
    fi
    ROOT_PART="$p"
    best="$sz"
  else
    BOOT_PART="$p"
  fi
done
[[ -n "$ROOT_PART" ]] || die "No ext4 root partition"

if [[ -z "${BOOT_PART}" ]]; then
  BOOT_PART="$(find_part_by_type vfat || true)"
fi

mkdir -p "$ROOT_MNT"
ok "Mounting root ${ROOT_PART}"
mount "$ROOT_PART" "$ROOT_MNT"

if [[ -n "${BOOT_PART}" && -d "${ROOT_MNT}/boot" ]]; then
  # Only bind-mount a separate boot fs if /boot is empty-ish or a mountpoint dir
  if ! mountpoint -q "${ROOT_MNT}/boot"; then
    if [[ -z "$(ls -A "${ROOT_MNT}/boot" 2>/dev/null | head -n 1)" ]] || \
       [[ "$(blkid -o value -s TYPE "$BOOT_PART" 2>/dev/null || true)" == "vfat" ]]; then
      ok "Mounting boot ${BOOT_PART}"
      mount "$BOOT_PART" "${ROOT_MNT}/boot"
      BOOT_MNT="${ROOT_MNT}/boot"
    fi
  fi
fi

[[ -x "${ROOT_MNT}/bin/bash" ]] || die "Image root does not look like a Linux rootfs"

host_arch="$(uname -m)"
img_arch="$(file -b "${ROOT_MNT}/bin/bash" | sed -n 's/.* \([^ ]*\) executable.*/\1/p')"
ok "Host arch ${host_arch} / image $(file -b "${ROOT_MNT}/bin/bash")"

if [[ "$host_arch" != "aarch64" && "$host_arch" != "arm64" ]]; then
  if ! [[ -x /usr/bin/qemu-aarch64-static || -x "${ROOT_MNT}/usr/bin/qemu-aarch64-static" ]]; then
    warn "Cross-arch customize needs qemu-user-static (apt install qemu-user-static binfmt-support)"
  fi
  if [[ -x /usr/bin/qemu-aarch64-static && ! -e "${ROOT_MNT}/usr/bin/qemu-aarch64-static" ]]; then
    mkdir -p "${ROOT_MNT}/usr/bin"
    cp -a /usr/bin/qemu-aarch64-static "${ROOT_MNT}/usr/bin/"
  fi
fi

DEST="${ROOT_MNT}/home/${TARGET_USER}/OpenNept4une"
ok "Copying repo to ${DEST}"
mkdir -p "${ROOT_MNT}/home/${TARGET_USER}"
rsync -a --delete "$REPO_ROOT/" "$DEST/"

# resolv.conf so apt/git work in the chroot
if [[ -f /etc/resolv.conf ]]; then
  mkdir -p "${ROOT_MNT}/etc"
  cp -L /etc/resolv.conf "${ROOT_MNT}/etc/resolv.conf" || true
fi

prepare_manual_chroot() {
  mkdir -p "${ROOT_MNT}/dev" "${ROOT_MNT}/proc" "${ROOT_MNT}/sys" "${ROOT_MNT}/dev/pts" "${ROOT_MNT}/run"
  mountpoint -q "${ROOT_MNT}/dev" || mount --bind /dev "${ROOT_MNT}/dev"
  mountpoint -q "${ROOT_MNT}/proc" || mount --bind /proc "${ROOT_MNT}/proc"
  mountpoint -q "${ROOT_MNT}/sys" || mount --bind /sys "${ROOT_MNT}/sys"
  mountpoint -q "${ROOT_MNT}/dev/pts" || mount -t devpts devpts "${ROOT_MNT}/dev/pts" || true
  mountpoint -q "${ROOT_MNT}/run" || mount -t tmpfs tmpfs "${ROOT_MNT}/run" || true
}

run_in_image() {
  local script="$1"
  shift
  if command -v systemd-nspawn >/dev/null 2>&1; then
    ok "systemd-nspawn ${script}"
    if systemd-nspawn \
      --directory="$ROOT_MNT" \
      --machine="on4-$$-${RANDOM}" \
      --resolv-conf=off \
      --bind-ro=/etc/resolv.conf:/etc/resolv.conf \
      /usr/bin/env TARGET_USER="$TARGET_USER" IMAGE_BAKE=1 \
      "$script" "$@"; then
      return 0
    fi
    warn "nspawn failed; falling back to chroot"
  fi

  ok "chroot ${script}"
  prepare_manual_chroot
  chroot "$ROOT_MNT" /usr/bin/env TARGET_USER="$TARGET_USER" IMAGE_BAKE=1 \
    "$script" "$@"
}

run_in_image "/home/${TARGET_USER}/OpenNept4une/img-config/image-bake-install.sh"

ok "Running cleanup --bake inside the image"
run_in_image "/home/${TARGET_USER}/OpenNept4une/img-config/dev-image-cleanup.sh" --bake

# Flush and detach so shrink can reopen the file
sync
cleanup
trap - EXIT
LOOP=""
BOOT_MNT=""

stamp="$(date +%Y%m%d)"
OUT="${WORK_DIR}/OpenNept4une-customized-$(repo_branch)-${stamp}.img"
mkdir -p "$WORK_DIR"
cp -f "$IMG" "$OUT"
ok "Customized image: ${OUT}"
echo
echo "Next: sudo ${SCRIPT_DIR}/03-shrink-pack.sh ${OUT}"
