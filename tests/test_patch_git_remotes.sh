#!/usr/bin/env bash
# Isolated smoke test for tests/patch-git-remotes.sh.
# Builds a throwaway $HOME and never touches the repo checkout remotes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$ROOT/tests/patch-git-remotes.sh"
TEMPLATE="$ROOT/tests/sandbox-moonraker.conf"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$*"; }

[[ -x "$PATCH" || -f "$PATCH" ]] || fail "missing $PATCH"
[[ -f "$TEMPLATE" ]] || fail "missing $TEMPLATE"

git_cfg() {
    git -C "$1" config user.email "ci@example.test"
    git -C "$1" config user.name "ci"
}

# Seed a repo with main + a topic branch, then clone it into dest.
make_seed() {
    local seed="$1" topic="${2:-}"
    rm -rf "$seed"
    mkdir -p "$seed"
    git -C "$seed" init -q -b main
    git_cfg "$seed"
    printf 'seed\n' >"$seed/README"
    git -C "$seed" add README
    git -C "$seed" commit -q -m "init"
    if [[ -n "$topic" ]]; then
        git -C "$seed" checkout -q -b "$topic"
        printf 'topic\n' >>"$seed/README"
        git -C "$seed" add README
        git -C "$seed" commit -q -m "topic"
        git -C "$seed" checkout -q main
    fi
}

clone_into() {
    local seed="$1" dest="$2" origin_url="$3"
    rm -rf "$dest"
    git clone -q --origin origin "$seed" "$dest"
    git_cfg "$dest"
    git -C "$dest" remote set-url origin "$origin_url"
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/onp-patch-git.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

HOME_DIR="$WORKDIR/home"
SEED="$WORKDIR/seed"
FORK="$WORKDIR/fork.git"
mkdir -p "$HOME_DIR/printer_data/config"
mkdir -p "$SEED" "$WORKDIR/empty"

# --- safety: script must not rewrite this checkout ---
echo "== refuse GitHub workspace / real checkout without --home =="
if GITHUB_WORKSPACE="$ROOT" bash "$PATCH" --opennept4une-origin https://example.test/fork.git 2>"$WORKDIR/err.txt"; then
    fail "script ran without --home in a fake GITHUB_WORKSPACE"
fi
grep -qi "sudo\|--home\|GITHUB_WORKSPACE\|Refusing" "$WORKDIR/err.txt" \
    || fail "expected a refusal/sudo error, got: $(cat "$WORKDIR/err.txt")"
ok "refuses to run against the workflow checkout"

before_origin="$(git -C "$ROOT" remote get-url origin)"
ok "recorded checkout origin: ${before_origin}"

# --- fixtures ---
echo "== fixtures =="
make_seed "$SEED/OpenNept4une" "topic-branch"
make_seed "$SEED/klipper"
make_seed "$SEED/moonraker"
git clone -q --bare "$SEED/OpenNept4une" "$FORK"
git -C "$FORK" symbolic-ref HEAD refs/heads/main

clone_into "$SEED/OpenNept4une" "$HOME_DIR/OpenNept4une" \
    "https://github.com/OpenNeptune3D/OpenNept4une.git"
clone_into "$SEED/klipper" "$HOME_DIR/klipper" \
    "https://github.com/Klipper3d/klipper.git"
clone_into "$SEED/moonraker" "$HOME_DIR/moonraker" \
    "https://github.com/Arksine/moonraker.git"

# Official-looking moonraker.conf; path uses /home/mks like the template.
sed "s|/home/mks|${HOME_DIR}|g" "$TEMPLATE" >"$HOME_DIR/printer_data/config/moonraker.conf"

# Snapshot lines that must not change unless we ask.
cp "$HOME_DIR/printer_data/config/moonraker.conf" "$WORKDIR/moonraker.before"

echo "== patch remotes in throwaway home =="
bash "$PATCH" \
    --home "$HOME_DIR" \
    --opennept4une-origin "$FORK" \
    --opennept4une-branch topic-branch \
    --opennept4une-upstream https://github.com/OpenNeptune3D/OpenNept4une.git \
    --klipper-origin https://example.test/klipper-fork.git \
    --moonraker-origin https://example.test/moonraker-fork.git \
    --no-unshallow

after_checkout_origin="$(git -C "$ROOT" remote get-url origin)"
[[ "$after_checkout_origin" = "$before_origin" ]] \
    || fail "script rewrote the real checkout origin: ${after_checkout_origin}"
ok "real checkout origin unchanged"

onp_origin="$(git -C "$HOME_DIR/OpenNept4une" remote get-url origin)"
onp_upstream="$(git -C "$HOME_DIR/OpenNept4une" remote get-url upstream)"
klip_origin="$(git -C "$HOME_DIR/klipper" remote get-url origin)"
moon_origin="$(git -C "$HOME_DIR/moonraker" remote get-url origin)"
onp_branch="$(git -C "$HOME_DIR/OpenNept4une" branch --show-current)"

[[ "$onp_origin" = "$FORK" ]] || fail "OpenNept4une origin: ${onp_origin}"
[[ "$onp_upstream" = "https://github.com/OpenNeptune3D/OpenNept4une.git" ]] \
    || fail "OpenNept4une upstream: ${onp_upstream}"
[[ "$klip_origin" = "https://example.test/klipper-fork.git" ]] \
    || fail "klipper origin: ${klip_origin}"
[[ "$moon_origin" = "https://example.test/moonraker-fork.git" ]] \
    || fail "moonraker origin: ${moon_origin}"
[[ "$onp_branch" = "topic-branch" ]] || fail "OpenNept4une branch: ${onp_branch}"
ok "git remotes and topic branch updated"

conf="$HOME_DIR/printer_data/config/moonraker.conf"
grep -F "origin: ${FORK}" "$conf" | grep -q . \
    || fail "moonraker.conf missing OpenNept4une fork origin"
grep -q "primary_branch: topic-branch" "$conf" \
    || fail "moonraker.conf missing topic primary_branch"
grep -q "origin: https://example.test/klipper-fork.git" "$conf" \
    || fail "moonraker.conf missing klipper fork origin"
grep -q "origin: https://example.test/moonraker-fork.git" "$conf" \
    || fail "moonraker.conf missing moonraker fork origin"
grep -q "repo: fluidd-core/fluidd" "$conf" \
    || fail "fluidd section was damaged"
grep -q "origin: https://github.com/kyleisah/Klipper-Adaptive-Meshing-Purging.git" "$conf" \
    || fail "KAMP origin was rewritten"
if grep -q "origin: https://github.com/OpenNeptune3D/OpenNept4une.git" "$conf"; then
    fail "official OpenNept4une origin still present after retarget"
fi
ok "moonraker.conf origins patched; unrelated sections left alone"

# Official remotes must not have been added to the real checkout.
if git -C "$ROOT" remote | grep -qx upstream; then
    : # may already exist on a developer machine; do not fail
fi
git -C "$ROOT" remote -v | grep -q "example.test" \
    && fail "example.test remote leaked into the real checkout"
ok "no leak into the workflow checkout remotes"

echo "== --help =="
bash "$PATCH" --help | grep -q "\-\-home" || fail "help missing --home"
ok "help documents --home"

echo
echo "patch-git-remotes smoke passed (throwaway tree only)."
