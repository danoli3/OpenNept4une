#!/usr/bin/env bash
# Unattended OpenNept4une image contents: Klipper, Moonraker, Fluidd, Mainsail,
# KAMP, display_connector, mobileraker, printer_data defaults.
#
# Replaces interactive KIAUH during a release bake.
# Run on a freshly booted Armbian ZNP-K1 image, or from img-build nspawn:
#   sudo TARGET_USER=mks ./img-config/image-bake-install.sh
#
# Does not write printer.cfg — first boot still selects the model.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: run with sudo:  sudo $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
if [[ -f "${REPO_DIR}/img-build/config.env" ]]; then
  # shellcheck disable=SC1091
  source "${REPO_DIR}/img-build/config.env"
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-mks}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" = "root" ]]; then
  echo "Error: set TARGET_USER (usually mks)" >&2
  exit 1
fi

die() { echo "Error: $*" >&2; exit 1; }
ok() { echo "==> $*"; }
warn() { echo "Warning: $*" >&2; }

export DEBIAN_FRONTEND=noninteractive

is_live() {
  [[ -d /run/systemd/system ]] && systemctl is-system-running >/dev/null 2>&1
}

as_user() {
  sudo -u "$TARGET_USER" --preserve-env=HOME env HOME="$TARGET_HOME" "$@"
}

ensure_user() {
  if id "$TARGET_USER" >/dev/null 2>&1; then
    return 0
  fi
  ok "Creating user ${TARGET_USER}"
  useradd -m -s /bin/bash -G sudo,dialout,tty,video "$TARGET_USER"
  if [[ -n "${TARGET_PASSWORD:-}" ]]; then
    echo "${TARGET_USER}:${TARGET_PASSWORD}" | chpasswd
  fi
  echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${TARGET_USER}"
  chmod 440 "/etc/sudoers.d/${TARGET_USER}"
}

clone_or_update() {
  local url="$1" dest="$2" branch="${3:-}"
  if [[ -d "${dest}/.git" ]]; then
    ok "Updating ${dest}"
    if [[ -n "$branch" ]]; then
      as_user git -C "$dest" fetch --prune origin || true
      as_user git -C "$dest" checkout "$branch" || true
    fi
    as_user git -C "$dest" pull --ff-only || true
  else
    ok "Cloning ${url}"
    if [[ -n "$branch" ]]; then
      as_user git clone --branch "$branch" "$url" "$dest" \
        || as_user git clone "$url" "$dest"
    else
      as_user git clone "$url" "$dest"
    fi
  fi
}

sync_this_repo() {
  local dest="${TARGET_HOME}/OpenNept4une"
  if [[ "$REPO_DIR" == "$dest" ]]; then
    ok "Already running from ${dest}"
    return 0
  fi
  ok "Copying this checkout to ${dest}"
  mkdir -p "$dest"
  rsync -a --delete \
    --exclude '.git/objects/pack/*.keep' \
    "$REPO_DIR/" "$dest/"
  chown -R "${TARGET_USER}:${TARGET_USER}" "$dest"
}

write_nginx_sites() {
  local fluidd_dir="$1" mainsail_dir="$2"
  cat > /etc/nginx/sites-available/fluidd <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root ${fluidd_dir};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /websocket {
        proxy_pass http://127.0.0.1:7125/websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }

    location ~ ^/(printer|api|access|machine|server)/ {
        proxy_pass http://127.0.0.1:7125\$request_uri;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

  cat > /etc/nginx/sites-available/mainsail <<EOF
server {
    listen 81 default_server;
    listen [::]:81 default_server;
    server_name _;
    root ${mainsail_dir};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /websocket {
        proxy_pass http://127.0.0.1:7125/websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }

    location ~ ^/(printer|api|access|machine|server)/ {
        proxy_pass http://127.0.0.1:7125\$request_uri;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/default
  ln -sfn /etc/nginx/sites-available/fluidd /etc/nginx/sites-enabled/fluidd
  if [[ "${INSTALL_MAINSAIL}" == "1" ]]; then
    ln -sfn /etc/nginx/sites-available/mainsail /etc/nginx/sites-enabled/mainsail
  fi
  nginx -t || warn "nginx -t failed (ok in a chroot without full runtime)"
}

write_klipper_unit() {
  cat > /etc/systemd/system/klipper.service <<EOF
[Unit]
Description=Klipper 3D Printer Firmware
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TARGET_USER}
RemainAfterExit=yes
ExecStart=${TARGET_HOME}/klippy-env/bin/python ${TARGET_HOME}/klipper/klippy/klippy.py ${TARGET_HOME}/printer_data/config/printer.cfg -l ${TARGET_HOME}/printer_data/logs/klippy.log -a ${TARGET_HOME}/printer_data/comms/klippy.sock
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

write_moonraker_unit() {
  cat > /etc/systemd/system/moonraker.service <<EOF
[Unit]
Description=Moonraker
After=network-online.target klipper.service
Wants=network-online.target

[Service]
Type=simple
User=${TARGET_USER}
ExecStart=${TARGET_HOME}/moonraker-env/bin/python ${TARGET_HOME}/moonraker/moonraker/moonraker.py -d ${TARGET_HOME}/printer_data
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

write_mobileraker_unit() {
  cat > /etc/systemd/system/mobileraker.service <<EOF
[Unit]
Description=Mobileraker Companion
After=network-online.target moonraker.service
Wants=network-online.target

[Service]
Type=simple
User=${TARGET_USER}
WorkingDirectory=${TARGET_HOME}/mobileraker_companion
ExecStart=${TARGET_HOME}/mobileraker-env/bin/python ${TARGET_HOME}/mobileraker_companion/mobileraker.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

enable_unit() {
  local unit="$1"
  systemctl enable "$unit" >/dev/null 2>&1 || true
  if is_live; then
    systemctl daemon-reload || true
    systemctl restart "$unit" || warn "could not start ${unit}"
  fi
}

unzip_web() {
  local url="$1" dest="$2" name="$3"
  as_user mkdir -p "$dest"
  if [[ -f "${dest}/index.html" ]]; then
    ok "${name} already present"
    return 0
  fi
  ok "Installing ${name}"
  local tmp
  tmp="$(as_user mktemp "${TARGET_HOME}/${name}.XXXXXX.zip")"
  as_user wget -O "$tmp" "$url" || die "${name} download failed"
  [[ -s "$tmp" ]] || die "${name} download was empty"
  as_user unzip -t "$tmp" >/dev/null || die "${name} zip is not valid"
  as_user unzip -qo "$tmp" -d "$dest"
  rm -f "$tmp"
  [[ -f "${dest}/index.html" ]] || die "${name} extract did not produce index.html"
  chown -R "${TARGET_USER}:${TARGET_USER}" "$dest"
}

ensure_user
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Cannot resolve home for ${TARGET_USER}"

BAKE_BRANCH="${OPENNEPT4UNE_BRANCH:-$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")}"
DISPLAY_BRANCH="${DISPLAY_CONNECTOR_BRANCH:-${BAKE_BRANCH:-main}}"

KLIPPER_DIR="${TARGET_HOME}/klipper"
MOONRAKER_DIR="${TARGET_HOME}/moonraker"
FLUIDD_DIR="${TARGET_HOME}/fluidd"
MAINSAIL_DIR="${TARGET_HOME}/mainsail"
KAMP_DIR="${TARGET_HOME}/Klipper-Adaptive-Meshing-Purging"
KIAUH_DIR="${TARGET_HOME}/kiauh"
DISPLAY_DIR="${TARGET_HOME}/display_connector"
MOBILERAKER_DIR="${TARGET_HOME}/mobileraker_companion"
PDIR="${TARGET_HOME}/printer_data"
PCONFIG="${PDIR}/config"
PLOGS="${PDIR}/logs"

ok "TARGET_USER=${TARGET_USER} HOME=${TARGET_HOME} live=$(is_live && echo yes || echo no)"

# ---- base OS bits (no interactive KIAUH) ----
ok "Base image configuration (RUN_KIAUH=0)"
TARGET_USER="$TARGET_USER" RUN_KIAUH=0 bash "${REPO_DIR}/img-config/base_image_configuration.sh"

sync_this_repo
ON_DIR="${TARGET_HOME}/OpenNept4une"

ok "Installing packages"
apt-get update
apt-get install -y \
  git wget curl unzip sudo rsync \
  python3 python3-venv python3-dev python3-pip \
  build-essential libffi-dev libncurses-dev libusb-dev \
  libjpeg-dev zlib1g-dev libsodium-dev liblmdb-dev \
  pkg-config virtualenv \
  nginx \
  stm32flash dfu-util \
  gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi \
  libopenblas-dev python3-numpy python3-matplotlib \
  libopenjp2-7 libsystemd-dev setserial python3-systemd \
  v4l-utils wireless-tools crudini

# ---- repos ----
clone_or_update "$KLIPPER_REPO" "$KLIPPER_DIR"
clone_or_update "$MOONRAKER_REPO" "$MOONRAKER_DIR"
clone_or_update "$KAMP_REPO" "$KAMP_DIR"
clone_or_update "$KIAUH_REPO" "$KIAUH_DIR"

if [[ "${INSTALL_DISPLAY}" == "1" ]]; then
  clone_or_update "$DISPLAY_CONNECTOR_REPO" "$DISPLAY_DIR" "$DISPLAY_BRANCH"
fi
if [[ "${INSTALL_MOBILERAKER}" == "1" ]]; then
  clone_or_update "$MOBILERAKER_REPO" "$MOBILERAKER_DIR"
fi

ok "printer_data layout"
as_user mkdir -p "$PCONFIG" "$PLOGS" "${PDIR}/gcodes" "${PDIR}/database" "${PDIR}/comms"
if [[ ! -L "${PCONFIG}/KAMP" ]]; then
  as_user ln -sfn "${KAMP_DIR}/Configuration" "${PCONFIG}/KAMP"
fi

# Seed configs used by the first-run installer; no printer.cfg.
for f in moonraker.conf KAMP_Settings.cfg mainsail.cfg adxl.cfg klipper_debug.cfg; do
  src="${ON_DIR}/img-config/printer-data/${f}"
  if [[ -f "$src" ]]; then
    as_user cp -f "$src" "${PCONFIG}/${f}"
  fi
done
if [[ -f "${ON_DIR}/img-config/printer-data/moonraker.asvc" ]]; then
  as_user cp -f "${ON_DIR}/img-config/printer-data/moonraker.asvc" "${PDIR}/moonraker.asvc"
fi
if [[ -f "${ON_DIR}/img-config/printer-data/data.mdb" && ! -f "${PDIR}/database/data.mdb" ]]; then
  as_user cp -f "${ON_DIR}/img-config/printer-data/data.mdb" "${PDIR}/database/data.mdb"
fi
if [[ ! -f "${PCONFIG}/user_settings.cfg" ]]; then
  as_user tee "${PCONFIG}/user_settings.cfg" >/dev/null <<'EOF'
# User overrides kept across OpenNept4une printer.cfg regenerations.
EOF
fi
# Release images must not ship a model-specific printer.cfg.
rm -f "${PCONFIG}/printer.cfg" "${TARGET_HOME}/printer.cfg"

# ---- Python venvs ----
if [[ ! -x "${TARGET_HOME}/klippy-env/bin/python" ]]; then
  ok "Creating klippy-env"
  as_user python3 -m venv "${TARGET_HOME}/klippy-env"
  as_user "${TARGET_HOME}/klippy-env/bin/pip" install -U pip setuptools wheel
  as_user "${TARGET_HOME}/klippy-env/bin/pip" install -r "${KLIPPER_DIR}/scripts/klippy-requirements.txt"
else
  ok "klippy-env already present"
fi

if [[ ! -x "${TARGET_HOME}/moonraker-env/bin/python" ]]; then
  ok "Creating moonraker-env"
  as_user python3 -m venv "${TARGET_HOME}/moonraker-env"
  as_user "${TARGET_HOME}/moonraker-env/bin/pip" install -U pip setuptools wheel
  as_user "${TARGET_HOME}/moonraker-env/bin/pip" install -r "${MOONRAKER_DIR}/scripts/moonraker-requirements.txt"
else
  ok "moonraker-env already present"
fi

if [[ "${INSTALL_FLUIDD}" == "1" ]]; then
  unzip_web "$FLUIDD_ZIP" "$FLUIDD_DIR" "Fluidd"
fi
if [[ "${INSTALL_MAINSAIL}" == "1" ]]; then
  unzip_web "$MAINSAIL_ZIP" "$MAINSAIL_DIR" "Mainsail"
fi

chmod 755 "$TARGET_HOME"
write_nginx_sites "$FLUIDD_DIR" "$MAINSAIL_DIR"
systemctl enable nginx >/dev/null 2>&1 || true

write_klipper_unit
write_moonraker_unit
enable_unit klipper.service
enable_unit moonraker.service

# ---- virtual Linux MCU ----
if [[ "${INSTALL_VIRTUAL_MCU}" == "1" && -f "${ON_DIR}/mcu-firmware/virtualmcu.config" ]]; then
  ok "Building virtual MCU"
  as_user cp "${ON_DIR}/mcu-firmware/virtualmcu.config" "${KLIPPER_DIR}/.config"
  as_user make -C "$KLIPPER_DIR" olddefconfig
  as_user make -C "$KLIPPER_DIR" -j"$(nproc)"
  if [[ -f "${KLIPPER_DIR}/scripts/klipper-mcu.service" ]]; then
    cp "${KLIPPER_DIR}/scripts/klipper-mcu.service" /etc/systemd/system/klipper-mcu.service
    enable_unit klipper-mcu.service
  fi
  if is_live; then
    make -C "$KLIPPER_DIR" flash || warn "virtual MCU flash failed; continuing"
  fi
fi

# ---- display_connector ----
if [[ "${INSTALL_DISPLAY}" == "1" && -d "$DISPLAY_DIR" ]]; then
  ok "Installing display_connector"
  if [[ -x "${DISPLAY_DIR}/display-env-install.sh" ]]; then
    as_user env PROJECT_DIR="$DISPLAY_DIR" bash "${DISPLAY_DIR}/display-env-install.sh" \
      || warn "display-env-install.sh failed"
  fi
  if [[ -f "${DISPLAY_DIR}/display.service" ]]; then
    cp "${DISPLAY_DIR}/display.service" /etc/systemd/system/display.service
    enable_unit display.service
  fi
  if [[ -f "${DISPLAY_DIR}/affinity-setup.sh" ]]; then
    cp "${DISPLAY_DIR}/affinity-setup.sh" /usr/local/sbin/affinity-setup.sh
    chmod +x /usr/local/sbin/affinity-setup.sh
  fi
  if [[ -f "${DISPLAY_DIR}/affinity.service" ]]; then
    cp "${DISPLAY_DIR}/affinity.service" /etc/systemd/system/affinity.service
    enable_unit affinity.service
  fi
  chown -R "${TARGET_USER}:${TARGET_USER}" "$DISPLAY_DIR"
fi

# ---- mobileraker ----
if [[ "${INSTALL_MOBILERAKER}" == "1" && -d "$MOBILERAKER_DIR" ]]; then
  ok "Installing mobileraker"
  if [[ ! -x "${TARGET_HOME}/mobileraker-env/bin/python" ]]; then
    as_user python3 -m venv "${TARGET_HOME}/mobileraker-env"
    as_user "${TARGET_HOME}/mobileraker-env/bin/pip" install -U pip setuptools wheel
    if [[ -f "${MOBILERAKER_DIR}/scripts/mobileraker-requirements.txt" ]]; then
      as_user "${TARGET_HOME}/mobileraker-env/bin/pip" install -r \
        "${MOBILERAKER_DIR}/scripts/mobileraker-requirements.txt"
    fi
  fi
  write_mobileraker_unit
  enable_unit mobileraker.service
fi

# ---- OpenNept4une host glue (run_fixes, no model) ----
ok "Host glue"
if ! getent group gpio >/dev/null; then groupadd gpio; fi
if ! getent group spiusers >/dev/null; then groupadd spiusers; fi
usermod -a -G gpio,spiusers,dialout,tty,video "$TARGET_USER" || true

ln -sfn "${ON_DIR}/OpenNept4une.sh" /usr/local/bin/opennept4une
ln -sfn "${ON_DIR}/pictures/logo_opennept4une.svg" "${FLUIDD_DIR}/logo_opennept4une.svg" || true

FLAG_FILE="/boot/.OpenNept4une.txt"
touch "$FLAG_FILE"
if ! grep -qF "$(uname -a)" "$FLAG_FILE" 2>/dev/null; then
  uname -a >> "$FLAG_FILE"
fi
# Release images must not pin a printer model.
sed -i '/^N4/Id;/^n4/Id' "$FLAG_FILE" || true

if [[ ! -f /etc/systemd/system/power_monitor.service ]]; then
  cat > /etc/systemd/system/power_monitor.service <<EOF
[Unit]
Description=Power Cut Monitor and Safe Shutdown

[Service]
Type=simple
ExecStart=${ON_DIR}/img-config/power_monitor.sh
User=root
Restart=no

[Install]
WantedBy=multi-user.target
EOF
  enable_unit power_monitor.service
fi

if ! crontab -u "$TARGET_USER" -l 2>/dev/null | grep -q '/bin/sync'; then
  (crontab -u "$TARGET_USER" -l 2>/dev/null | grep -v '/bin/sync' || true
   echo "*/10 * * * * /bin/sync") | crontab -u "$TARGET_USER" -
fi

LOGIND_CONF="/etc/systemd/logind.conf"
if [[ -f "$LOGIND_CONF" ]]; then
  sed -i 's/^[#]*HandlePowerKey=.*/HandlePowerKey=ignore/' "$LOGIND_CONF" || true
  sed -i 's/^[#]*HandlePowerKeyLongPress=.*/HandlePowerKeyLongPress=ignore/' "$LOGIND_CONF" || true
fi

# DTB copies from this repo (Armbian overlay may already have them)
if [[ -d /boot/dtb/rockchip ]]; then
  shopt -s nullglob
  for dtb in "${ON_DIR}/dtb"/*/*.dtb; do
    cp -f "$dtb" /boot/dtb/rockchip/
  done
  shopt -u nullglob
fi

chown -R "${TARGET_USER}:${TARGET_USER}" "$PDIR" "$ON_DIR"

ok "Used-space report"
if command -v du >/dev/null; then
  du -xh --max-depth=1 "$TARGET_HOME" 2>/dev/null | sort -h | tail -n 20 || true
  echo
  df -h / /boot 2>/dev/null || true
fi

echo
ok "Image contents installed"
echo "Next: sudo ${ON_DIR}/img-config/dev-image-cleanup.sh --bake"
echo "Then dump the eMMC/SD and run img-build/03-shrink-pack.sh"
echo "After flash, first boot still runs opennept4une to pick the printer model."
