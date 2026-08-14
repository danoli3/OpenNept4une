#!/usr/bin/env bash
# Tighten the host sandbox: nginx headers, optional UFW.
# Moonraker stays on 0.0.0.0:7125 unless you pass --localhost-only.
# Does not change a real printer image unless --force is passed.
set -euo pipefail

FORCE="false"
ENABLE_UFW="false"
FORCE_LOGINS="false"
LOCALHOST_ONLY="false"

usage() {
    cat <<'EOF'
Usage: sudo ./tests/harden-sandbox.sh [OPTIONS]

Security defaults for the Fluidd/Moonraker sandbox:

  - Leave Moonraker on 0.0.0.0:7125 (public on the guest NIC)
  - Add basic nginx security headers
  - Optionally enable UFW (OpenSSH, 80, 443, 7125)

Options:
  --ufw              enable UFW (allow OpenSSH, 80, 443, 7125)
  --localhost-only   bind Moonraker to 127.0.0.1 instead (Fluidd still works via nginx)
  --force-logins     set authorization.force_logins True (needs a Fluidd user)
  --force            allow running on a real OpenNept4une image
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ufw) ENABLE_UFW="true"; shift ;;
        --localhost-only) LOCALHOST_ONLY="true"; shift ;;
        --force-logins) FORCE_LOGINS="true"; shift ;;
        --force) FORCE="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: run with sudo:  sudo $0" >&2
    exit 1
fi

die() { echo "Error: $*" >&2; exit 1; }
ok() { echo "==> $*"; }

if [[ -f /boot/.OpenNept4une.txt && "$FORCE" != "true" ]]; then
    die "Refusing to harden a real OpenNept4une printer image. Pass --force if you meant to."
fi

TARGET_USER="${SUDO_USER:-mks}"
[[ "$TARGET_USER" = "root" ]] && TARGET_USER="mks"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
[[ -n "$TARGET_HOME" ]] || TARGET_HOME="/home/${TARGET_USER}"
MOON_CONF="${TARGET_HOME}/printer_data/config/moonraker.conf"
NGINX_SITE="/etc/nginx/sites-available/fluidd"

if [[ -f "$MOON_CONF" ]]; then
    ok "Updating moonraker.conf authorization options"
    python3 - "$MOON_CONF" "$FORCE_LOGINS" "$LOCALHOST_ONLY" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
force = sys.argv[2] == "true"
localhost_only = sys.argv[3] == "true"
host_value = "127.0.0.1" if localhost_only else "0.0.0.0"
lines = path.read_text().splitlines(True)
out = []
section = None
have_host = False
have_force = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if section == "server" and not have_host:
            out.append(f"host: {host_value}\n")
        if section == "authorization" and not have_force:
            out.append(f"force_logins: {'True' if force else 'False'}\n")
        section = stripped.strip("[]")
        have_host = False
        have_force = False
        out.append(line)
        continue
    if section == "server" and stripped.startswith("host:"):
        out.append(f"host: {host_value}\n")
        have_host = True
        continue
    if section == "authorization" and stripped.startswith("force_logins:"):
        out.append(f"force_logins: {'True' if force else 'False'}\n")
        have_force = True
        continue
    out.append(line)
if section == "server" and not have_host:
    out.append(f"host: {host_value}\n")
if section == "authorization" and not have_force:
    out.append(f"force_logins: {'True' if force else 'False'}\n")
path.write_text("".join(out))
PY
    chown "${TARGET_USER}:${TARGET_USER}" "$MOON_CONF"
    systemctl restart moonraker.service || true
fi

if [[ -f "$NGINX_SITE" ]]; then
    ok "Adding nginx security headers if missing"
    if ! grep -q "X-Content-Type-Options" "$NGINX_SITE"; then
        python3 - "$NGINX_SITE" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
header = """
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header Referrer-Policy no-referrer-when-downgrade;
    add_header X-Robots-Tag noindex;
"""
if "server_name" in text and "X-Content-Type-Options" not in text:
    text = text.replace("    index index.html;\n", "    index index.html;\n" + header, 1)
    # HTTPS server block may be the only one after redirect
    if "X-Content-Type-Options" not in text:
        text = text.replace("    ssl_protocols", header + "    ssl_protocols", 1)
path.write_text(text)
PY
        nginx -t && systemctl reload nginx
    fi
fi

if [[ "$ENABLE_UFW" = "true" ]]; then
    ok "Enabling UFW (OpenSSH, 80, 443, 7125)"
    apt-get install -y ufw >/dev/null
    ufw allow OpenSSH
    ufw allow 80/tcp
    ufw allow 443/tcp
    if [[ "$LOCALHOST_ONLY" != "true" ]]; then
        ufw allow 7125/tcp
    fi
    ufw --force enable
    ufw status
fi

ss_listen="$(ss -lnt 2>/dev/null | grep 7125 || true)"
echo
ok "Harden complete"
if [[ "$LOCALHOST_ONLY" = "true" ]]; then
    echo "Moonraker is localhost-only. Use Fluidd at https://<guest-ip>/"
else
    echo "Moonraker is public on the guest NIC: http://<guest-ip>:7125/"
    echo "Fluidd: https://<guest-ip>/"
fi
echo "${ss_listen:-  (check: ss -lnt | grep 7125)}"
if [[ "$FORCE_LOGINS" = "true" ]]; then
    echo "force_logins is on. Create a user in Fluidd Settings → Authentication."
fi
