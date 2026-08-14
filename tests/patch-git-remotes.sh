#!/usr/bin/env bash
# Point sandbox git checkouts and Moonraker update_manager at chosen remotes.
# Example: track your fork for OpenNept4une while Klipper/Moonraker stay official.
#
# This script rewrites git remotes and moonraker.conf. In CI it must be given
# --home pointing at a throwaway tree. It refuses to run in GitHub Actions
# against the workflow checkout.
set -euo pipefail

OPENNEPT4UNE_ORIGIN=""
OPENNEPT4UNE_BRANCH=""
OPENNEPT4UNE_UPSTREAM="${OPENNEPT4UNE_UPSTREAM:-https://github.com/OpenNeptune3D/OpenNept4une.git}"
KLIPPER_ORIGIN=""
MOONRAKER_ORIGIN=""
UNSHALLOW="true"
DO_FETCH="true"
DO_RESTART="true"
HOME_OVERRIDE=""
FORCE_WORKSPACE="false"

usage() {
    cat <<'EOF'
Usage: sudo ./tests/patch-git-remotes.sh [OPTIONS]

Rewire git remotes and Moonraker [update_manager] origins so Fluidd can
pull updates from GitHub. Shallow clones are unshallowed (Moonraker needs
full history).

Options:
  --opennept4une-origin URL    origin for ~/OpenNept4une (your fork)
  --opennept4une-branch NAME   checkout/track this branch
  --opennept4une-upstream URL  add/set upstream (default: OpenNeptune3D)
  --klipper-origin URL         origin for ~/klipper
  --moonraker-origin URL       origin for ~/moonraker
  --home DIR                   operate under DIR instead of the sudo user's home
                               (skips sudo, systemd restart, and the Actions guard)
  --no-unshallow               do not convert shallow clones
  --no-fetch                   do not git fetch after retargeting
  --no-restart                 do not restart moonraker.service
  --force-workspace            allow rewriting the repo that contains this script
  -h, --help

Examples:
  sudo ./tests/patch-git-remotes.sh \
    --opennept4une-origin https://github.com/danoli3/OpenNept4une.git \
    --opennept4une-branch tests/ci-and-host-sandbox

  OPENNEPT4UNE_ORIGIN=https://github.com/YOU/OpenNept4une.git sudo -E ./tests/patch-git-remotes.sh
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --opennept4une-origin) OPENNEPT4UNE_ORIGIN="$2"; shift 2 ;;
        --opennept4une-branch) OPENNEPT4UNE_BRANCH="$2"; shift 2 ;;
        --opennept4une-upstream) OPENNEPT4UNE_UPSTREAM="$2"; shift 2 ;;
        --klipper-origin) KLIPPER_ORIGIN="$2"; shift 2 ;;
        --moonraker-origin) MOONRAKER_ORIGIN="$2"; shift 2 ;;
        --home) HOME_OVERRIDE="$2"; shift 2 ;;
        --no-unshallow) UNSHALLOW="false"; shift ;;
        --no-fetch) DO_FETCH="false"; shift ;;
        --no-restart) DO_RESTART="false"; shift ;;
        --force-workspace) FORCE_WORKSPACE="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

die() { echo "Error: $*" >&2; exit 1; }
ok() { echo "==> $*"; }

if [[ -n "$HOME_OVERRIDE" ]]; then
    TARGET_USER="${USER:-$(id -un)}"
    TARGET_HOME="$(cd "$HOME_OVERRIDE" && pwd)"
    DO_RESTART="false"
    as_user() { env HOME="$TARGET_HOME" "$@"; }
elif [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: run with sudo:  sudo $0" >&2
    echo "Or pass --home DIR to operate on a throwaway tree (used by CI)." >&2
    exit 1
elif [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" = "root" ]]; then
    echo "Error: run via sudo from your normal user." >&2
    exit 1
else
    TARGET_USER="${SUDO_USER}"
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    [[ -n "$TARGET_HOME" ]] || die "Cannot resolve home for $TARGET_USER"
    as_user() {
        sudo -u "$TARGET_USER" --preserve-env=HOME env HOME="$TARGET_HOME" "$@"
    }
fi

MOON_CONF="${TARGET_HOME}/printer_data/config/moonraker.conf"

if [[ -n "${GITHUB_WORKSPACE:-}" && -z "$HOME_OVERRIDE" && "$FORCE_WORKSPACE" != "true" ]]; then
    die "Refusing to patch remotes in GitHub Actions without --home (refuses to touch the workflow checkout)."
fi

set_origin() {
    local repo="$1" url="$2"
    [[ -d "${repo}/.git" ]] || die "not a git repo: ${repo}"
    if as_user git -C "$repo" remote get-url origin >/dev/null 2>&1; then
        as_user git -C "$repo" remote set-url origin "$url"
    else
        as_user git -C "$repo" remote add origin "$url"
    fi
    ok "origin in ${repo} -> ${url}"
}

ensure_remote() {
    local repo="$1" name="$2" url="$3"
    [[ -d "${repo}/.git" ]] || return 0
    if as_user git -C "$repo" remote get-url "$name" >/dev/null 2>&1; then
        as_user git -C "$repo" remote set-url "$name" "$url"
    else
        as_user git -C "$repo" remote add "$name" "$url"
    fi
}

unshallow_repo() {
    local repo="$1"
    [[ -d "${repo}/.git" ]] || return 0
    if as_user git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null | grep -qx true; then
        ok "Unshallowing ${repo} (Moonraker update manager needs full history)"
        as_user git -C "$repo" fetch --unshallow --tags || as_user git -C "$repo" fetch --tags || true
    else
        as_user git -C "$repo" fetch --tags || true
    fi
}

patch_moonraker_origin() {
    local section="$1" url="$2"
    [[ -f "$MOON_CONF" ]] || return 0
    python3 - "$MOON_CONF" "$section" "$url" <<'PY'
from pathlib import Path
import sys
path, section, url = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
header = f"[update_manager {section}]"
lines = path.read_text().splitlines(True)
out = []
in_sec = False
replaced = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        in_sec = stripped == header
        out.append(line)
        continue
    if in_sec and stripped.startswith("origin:"):
        out.append(f"origin: {url}\n")
        replaced = True
        continue
    out.append(line)
if not replaced:
    sys.exit(0)
path.write_text("".join(out))
PY
    ok "moonraker.conf ${section} origin -> ${url}"
}

patch_moonraker_branch() {
    local section="$1" branch="$2"
    [[ -f "$MOON_CONF" ]] || return 0
    python3 - "$MOON_CONF" "$section" "$branch" <<'PY'
from pathlib import Path
import sys
path, section, branch = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
header = f"[update_manager {section}]"
lines = path.read_text().splitlines(True)
out = []
in_sec = False
replaced = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        in_sec = stripped == header
        out.append(line)
        continue
    if in_sec and stripped.startswith("primary_branch:"):
        out.append(f"primary_branch: {branch}\n")
        replaced = True
        continue
    out.append(line)
if not replaced:
    sys.exit(0)
path.write_text("".join(out))
PY
}

onp="${TARGET_HOME}/OpenNept4une"
klipper="${TARGET_HOME}/klipper"
moon="${TARGET_HOME}/moonraker"

if [[ "$FORCE_WORKSPACE" != "true" && -n "${GITHUB_WORKSPACE:-}" && -d "${onp}/.git" ]]; then
    onp_top="$(as_user git -C "$onp" rev-parse --show-toplevel 2>/dev/null || true)"
    ws="$(cd "${GITHUB_WORKSPACE}" && pwd)"
    if [[ -n "$onp_top" && "$onp_top" = "$ws" ]]; then
        die "Refusing to rewire GITHUB_WORKSPACE (${ws}). Pass --home pointing at a throwaway tree."
    fi
fi

if [[ "$UNSHALLOW" = "true" ]]; then
    unshallow_repo "$onp"
    unshallow_repo "$klipper"
    unshallow_repo "$moon"
    unshallow_repo "${TARGET_HOME}/Klipper-Adaptive-Meshing-Purging"
fi

if [[ -n "$OPENNEPT4UNE_ORIGIN" && -d "${onp}/.git" ]]; then
    set_origin "$onp" "$OPENNEPT4UNE_ORIGIN"
    if [[ -n "$OPENNEPT4UNE_UPSTREAM" ]]; then
        ensure_remote "$onp" upstream "$OPENNEPT4UNE_UPSTREAM"
        ok "upstream in ${onp} -> ${OPENNEPT4UNE_UPSTREAM}"
    fi
    patch_moonraker_origin OpenNept4une "$OPENNEPT4UNE_ORIGIN"
    if [[ "$DO_FETCH" = "true" ]]; then
        as_user git -C "$onp" fetch origin || true
    fi
    if [[ -n "$OPENNEPT4UNE_BRANCH" ]]; then
        if as_user git -C "$onp" show-ref --verify --quiet "refs/remotes/origin/${OPENNEPT4UNE_BRANCH}"; then
            as_user git -C "$onp" checkout -B "$OPENNEPT4UNE_BRANCH" "origin/${OPENNEPT4UNE_BRANCH}"
        else
            as_user git -C "$onp" checkout "$OPENNEPT4UNE_BRANCH" || true
        fi
        patch_moonraker_branch OpenNept4une "$OPENNEPT4UNE_BRANCH"
        ok "OpenNept4une branch ${OPENNEPT4UNE_BRANCH}"
    fi
fi

if [[ -n "$KLIPPER_ORIGIN" && -d "${klipper}/.git" ]]; then
    set_origin "$klipper" "$KLIPPER_ORIGIN"
    patch_moonraker_origin klipper "$KLIPPER_ORIGIN"
fi

if [[ -n "$MOONRAKER_ORIGIN" && -d "${moon}/.git" ]]; then
    set_origin "$moon" "$MOONRAKER_ORIGIN"
    patch_moonraker_origin moonraker "$MOONRAKER_ORIGIN"
fi

if [[ -f "$MOON_CONF" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
        chown "${TARGET_USER}:${TARGET_USER}" "$MOON_CONF" || true
    fi
    if [[ "$DO_RESTART" = "true" ]]; then
        systemctl restart moonraker.service || true
    fi
fi

echo
ok "Git remotes patched"
as_user git -C "$onp" remote -v 2>/dev/null || true
echo
echo "In Fluidd: Settings → Software Updates → Check for updates."
echo "Pull official OpenNept4une later with:  git -C ~/OpenNept4une fetch upstream && git merge upstream/dev"
