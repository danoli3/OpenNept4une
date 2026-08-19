#!/usr/bin/env bash
# Compile the ZNP-K1 Armbian base image.
# Needs Linux, ~50 GB disk, ~8 GB RAM. Docker is used if ./compile.sh prefers it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: $0

Clone ${ARMBIAN_REPO} (if needed) and run compile.sh for BOARD=${BOARD}.

Env (see img-build/config.env):
  ARMBIAN_DIR  BOARD  BRANCH  RELEASE
  INSTALL_HEADERS  EXTRAWIFI  BUILD_MINIMAL  FIXED_IMAGE_SIZE
EOF
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }

require_linux
need_cmd git

if [[ ! -x "${ARMBIAN_DIR}/compile.sh" ]]; then
  ok "Cloning Armbian-ZNP-K1-build into ${ARMBIAN_DIR}"
  mkdir -p "$(dirname "$ARMBIAN_DIR")"
  git clone --depth=1 --branch "$ARMBIAN_BRANCH" "$ARMBIAN_REPO" "$ARMBIAN_DIR"
else
  ok "Using existing ${ARMBIAN_DIR}"
fi

cd "$ARMBIAN_DIR"

args=(
  "BOARD=${BOARD}"
  "BRANCH=${BRANCH}"
  "RELEASE=${RELEASE}"
  "BSPFREEZE=${BSPFREEZE}"
  "BUILD_MINIMAL=${BUILD_MINIMAL}"
  "BUILD_DESKTOP=${BUILD_DESKTOP}"
  "KERNEL_CONFIGURE=${KERNEL_CONFIGURE}"
  "EXTRAWIFI=${EXTRAWIFI}"
  "INSTALL_HEADERS=${INSTALL_HEADERS}"
  "VENDOR=${VENDOR}"
  "COMPRESS_OUTPUTIMAGE=${COMPRESS_OUTPUTIMAGE}"
)
if [[ -n "${FIXED_IMAGE_SIZE}" ]]; then
  args+=("FIXED_IMAGE_SIZE=${FIXED_IMAGE_SIZE}")
fi

ok "compile.sh ${args[*]}"
./compile.sh "${args[@]}"

ok "Armbian output is under ${ARMBIAN_DIR}/output/images/"
ls -lh "${ARMBIAN_DIR}/output/images/" || true
echo
echo "Next: flash that image, boot, and run img-config/image-bake-install.sh"
echo "  or: sudo ./img-build/02-customize-nspawn.sh <armbian.img>"
