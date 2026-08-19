#!/usr/bin/env bash
# OpenNept4une flash-image bake entry point.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  armbian                         Compile the ZNP-K1 Armbian base image
  install                         Unattended contents install on THIS machine
                                  (freshly booted Armbian / the printer)
  nspawn <armbian.img>            Mount a base image and install into it
  shrink <img|img.xz|/dev/sdX>    Dump if needed, shrink to <= ${MAX_IMAGE_MIB} MiB, xz
  dtb <img> <v1x|v20>             Set the default board DTB
  all <armbian.img>               nspawn + shrink
  help                            This text

Typical on-printer bake (closest to how v0.1.7 was made):

  # after flashing a base Armbian image and SSH in as mks
  git clone -b $(repo_branch) <this-repo> ~/OpenNept4une
  sudo ~/OpenNept4une/img-config/image-bake-install.sh
  sudo ~/OpenNept4une/img-config/dev-image-cleanup.sh --bake
  sudo poweroff
  # pull the eMMC, on a Linux box:
  sudo $0 shrink /dev/sdX

Typical host bake (Linux, aarch64 preferred):

  sudo $0 armbian
  sudo $0 nspawn ${ARMBIAN_DIR}/output/images/*.img
  sudo $0 shrink ${WORK_DIR}/OpenNept4une-customized-*.img
  sudo $0 dtb <shrunk.img> v1x    # or v20

v0.1.7 uncompressed is 7456 MiB and overflows some 7.2 GiB eMMC chips.
shrink caps the published .img at MAX_IMAGE_MIB=${MAX_IMAGE_MIB}.

These steps need Linux. They will not run on macOS (use a Linux VM).
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  help|-h|--help) usage ;;
  armbian)
    exec bash "${SCRIPT_DIR}/01-build-armbian.sh" "$@"
    ;;
  install)
    require_root
    exec bash "${REPO_ROOT}/img-config/image-bake-install.sh" "$@"
    ;;
  nspawn)
    exec bash "${SCRIPT_DIR}/02-customize-nspawn.sh" "$@"
    ;;
  shrink|pack)
    exec bash "${SCRIPT_DIR}/03-shrink-pack.sh" "$@"
    ;;
  dtb)
    exec bash "${SCRIPT_DIR}/apply-dtb-variant.sh" "$@"
    ;;
  all)
    [[ $# -ge 1 ]] || die "all requires a base Armbian .img"
    bash "${SCRIPT_DIR}/02-customize-nspawn.sh" "$1"
    # last customized image in WORK_DIR
    latest="$(ls -t "${WORK_DIR}"/OpenNept4une-customized-*.img 2>/dev/null | head -n 1 || true)"
    [[ -n "$latest" ]] || die "customize did not produce an image in ${WORK_DIR}"
    exec bash "${SCRIPT_DIR}/03-shrink-pack.sh" "$latest"
    ;;
  *)
    usage >&2
    die "unknown command: ${cmd}"
    ;;
esac
