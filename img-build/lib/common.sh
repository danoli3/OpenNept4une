#!/usr/bin/env bash
# Shared helpers for img-build scripts. Source only.

if [[ -n "${ON4_COMMON_LOADED:-}" ]]; then
  return 0
fi
ON4_COMMON_LOADED=1

IMG_BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${IMG_BUILD_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${IMG_BUILD_DIR}/config.env"

die() { echo "Error: $*" >&2; exit 1; }
ok() { echo "==> $*"; }
warn() { echo "Warning: $*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "run with sudo: sudo $0 $*"
  fi
}

require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    die "This step needs Linux (losetup/sfdisk/chroot). On macOS use a Linux VM."
  fi
}

mib() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b / 1024 / 1024 }'
}

gib() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.3f", b / 1024 / 1024 / 1024 }'
}

bytes_of() {
  local p="$1"
  if [[ -b "$p" ]]; then
    blockdev --getsize64 "$p"
  else
    stat -c%s "$p" 2>/dev/null || stat -f%z "$p"
  fi
}

load_config() {
  local extra="${1:-}"
  if [[ -n "$extra" && -f "$extra" ]]; then
    # shellcheck disable=SC1090
    source "$extra"
  fi
}

repo_branch() {
  git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "dev"
}
