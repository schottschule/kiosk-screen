#!/usr/bin/env bash
set -euo pipefail

readonly KIOSK_USER="kiosk"
readonly KIOSK_HOME="/home/${KIOSK_USER}"
readonly CHROME_KEYRING="/usr/share/keyrings/google-chrome.gpg"
readonly CHROME_SOURCE_LIST="/etc/apt/sources.list.d/google-chrome.list"
readonly CHROME_POLICY_DIR="/etc/opt/chrome/policies/managed"
readonly CHROME_POLICY_FILE="${CHROME_POLICY_DIR}/kiosk-media.json"
readonly GDM_CONFIG="/etc/gdm3/custom.conf"
readonly POWEROFF_SERVICE="/etc/systemd/system/kiosk-poweroff.service"
readonly POWEROFF_TIMER="/etc/systemd/system/kiosk-poweroff.timer"

log() {
  printf '[kiosk-setup] %s\n' "$*"
}

fail() {
  printf '[kiosk-setup] Fehler: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "'${command_name}' wurde nicht gefunden."
}

single_quote_escape() {
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

prompt_nonempty() {
  local prompt="$1"
  local value=""

  while true; do
    read -r -p "$prompt" value
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    printf 'Bitte einen Wert eingeben.\n'
  done
}

prompt_url() {
  local value=""

  while true; do
    value="$(prompt_nonempty 'Basis-URL ohne Token (z. B. https://example.com/app): ')"
    value="${value%%#*}"
    if [[ "$value" =~ ^https?://.+$ ]]; then
      printf '%s' "$value"
      return 0
    fi
    printf 'Bitte eine URL mit http:// oder https:// eingeben.\n'
  done
}

prompt_poweroff_time() {
  local value=""

  while true; do
    read -r -p 'Tägliche Abschaltzeit in HH:MM (leer = kein Ausschalt-Timer): ' value
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -z "$value" ]]; then
      printf '%s' ""
      return 0
    fi
    if [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      printf '%s' "$value"
      return 0
    fi
    printf 'Bitte Uhrzeit im Format HH:MM eingeben, z. B. 16:00.\n'
  done
}

ensure_not_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    fail "Bitte als normaler Benutzer starten, nicht als root."
  fi
}

ensure_supported_os() {
  if [[ ! -f /etc/os-release ]]; then
    fail "/etc/os-release fehlt. Dieses Skript erwartet Ubuntu Desktop."
  fi

  if ! grep -qi 'ubuntu' /etc/os-release; then
    log "Warnung: Kein Ubuntu in /etc/os-release erkannt. Das Skript versucht es trotzdem."
  fi
}

ensure_sudo_session() {
  require_command sudo
  log "Sudo-Berechtigung wird geprüft."
  sudo -v
}

install_packages() {
  log "Pakete werden installiert."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg python3 xdg-user-dirs dbus-user-session

  if [[ ! -f "$CHROME_KEYRING" ]]; then
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor \
      | sudo tee "$CHROME_KEYRING" >/dev/null
  fi

  echo "deb [arch=amd64 signed-by=${CHROME_KEYRING}] https://dl.google.com/linux/chrome/deb/ stable main" \
    | sudo tee "$CHROME_SOURCE_LIST" >/dev/null

  sudo apt-get update
  sudo apt-get install -y google-chrome-stable
}

ensure_kiosk_user() {
  if id -u "$KIOSK_USER" >/dev/null 2>&1; then
    log "Benutzer '${KIOSK_USER}' existiert bereits."
  else
    log "Benutzer '${KIOSK_USER}' wird angelegt."
    sudo adduser --disabled-password --gecos "" "$KIOSK_USER"
  fi

  sudo usermod -a -G audio,video "$KIOSK_USER" || true
}

configure_gdm_autologin() {
  if [[ ! -f "$GDM_CONFIG" ]]; then
    log "Warnung: ${GDM_CONFIG} nicht gefunden. Autologin bitte manuell prüfen."
    return 0
  fi

  log "GDM-Autologin für '${KIOSK_USER}' wird gesetzt."
  sudo python3 - "$GDM_CONFIG" "$KIOSK_USER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
username = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
result = []
inside_daemon = False
daemon_seen = False
auto_enable_written = False
auto_user_written = False

for line in lines:
    stripped = line.strip()

    if stripped.startswith("[") and stripped.endswith("]"):
        if inside_daemon:
            if not auto_enable_written:
                result.append("AutomaticLoginEnable=True")
            if not auto_user_written:
                result.append(f"AutomaticLogin={username}")
        inside_daemon = stripped == "[daemon]"
        daemon_seen = daemon_seen or inside_daemon
        result.append(line)
        continue

    if inside_daemon and stripped.startswith("AutomaticLoginEnable="):
        result.append("AutomaticLoginEnable=True")
        auto_enable_written = True
        continue

    if inside_daemon and stripped.startswith("AutomaticLogin="):
        result.append(f"AutomaticLogin={username}")
        auto_user_written = True
        continue

    result.append(line)

if daemon_seen:
    if inside_daemon:
        if not auto_enable_written:
            result.append("AutomaticLoginEnable=True")
        if not auto_user_written:
            result.append(f"AutomaticLogin={username}")
else:
    if result and result[-1] != "":
        result.append("")
    result.extend([
        "[daemon]",
        "AutomaticLoginEnable=True",
        f"AutomaticLogin={username}",
    ])

path.write_text("\n".join(result) + "\n", encoding="utf-8")
PY
}

configure_kiosk_files() {
  local full_url="$1"
  local origin="$2"
  local escaped_url
  local escaped_origin
  local desktop_dir

  escaped_url="$(single_quote_escape "$full_url")"
  escaped_origin="$(single_quote_escape "$origin")"

  log "Kiosk-Startskript und Autostart werden eingerichtet."
  sudo install -d -m 755 -o "$KIOSK_USER" -g "$KIOSK_USER" \
    "$KIOSK_HOME/bin" \
    "$KIOSK_HOME/.local/share/applications" \
    "$KIOSK_HOME/.config/autostart"

  sudo tee "$KIOSK_HOME/bin/kiosk.sh" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail

URL='${escaped_url}'
ORIGIN='${escaped_origin}'
PROFILE_DIR="\$HOME/.config/google-chrome-kiosk"
STARTUP_DELAY_SECONDS="\${STARTUP_DELAY_SECONDS:-10}"
NETWORK_WAIT_SECONDS="\${NETWORK_WAIT_SECONDS:-60}"
NETWORK_RETRY_INTERVAL="\${NETWORK_RETRY_INTERVAL:-2}"
LOG_FILE="\$HOME/.cache/kiosk-start.log"

log() {
  mkdir -p "\$(dirname "\$LOG_FILE")"
  printf '[%s] %s\n' "\$(date '+%F %T')" "\$*" >> "\$LOG_FILE"
}

wait_for_target() {
  local waited=0

  sleep "\$STARTUP_DELAY_SECONDS"

  if command -v nm-online >/dev/null 2>&1; then
    nm-online -q --timeout="\$NETWORK_WAIT_SECONDS" || true
  fi

  while (( waited < NETWORK_WAIT_SECONDS )); do
    if curl --silent --show-error --fail --location --max-time 5 --output /dev/null "\$ORIGIN"; then
      log "Netzwerk und Ziel erreichbar."
      return 0
    fi

    sleep "\$NETWORK_RETRY_INTERVAL"
    waited=\$((waited + NETWORK_RETRY_INTERVAL))
  done

  log "Ziel nach \${NETWORK_WAIT_SECONDS}s nicht erreichbar, Chrome wird trotzdem gestartet."
}

mkdir -p "\$PROFILE_DIR"
wait_for_target

exec /usr/bin/google-chrome-stable \
  --kiosk \
  --no-first-run \
  --disable-session-crashed-bubble \
  --noerrdialogs \
  --autoplay-policy=no-user-gesture-required \
  --user-data-dir="\$PROFILE_DIR" \
  "\$URL"
EOF
  sudo chmod 755 "$KIOSK_HOME/bin/kiosk.sh"

  sudo tee "$KIOSK_HOME/.local/share/applications/kiosk-chrome.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=Kiosk Chrome
Comment=Startet den Kiosk-Browser
Exec=${KIOSK_HOME}/bin/kiosk.sh
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=false
X-GNOME-Autostart-Delay=10
EOF
  sudo chmod 755 "$KIOSK_HOME/.local/share/applications/kiosk-chrome.desktop"
  sudo cp "$KIOSK_HOME/.local/share/applications/kiosk-chrome.desktop" "$KIOSK_HOME/.config/autostart/kiosk-chrome.desktop"

  desktop_dir="$(
    sudo -u "$KIOSK_USER" HOME="$KIOSK_HOME" xdg-user-dir DESKTOP 2>/dev/null \
      || printf '%s' "${KIOSK_HOME}/Desktop"
  )"
  if [[ -z "$desktop_dir" ]]; then
    desktop_dir="${KIOSK_HOME}/Desktop"
  fi
  sudo install -d -m 755 -o "$KIOSK_USER" -g "$KIOSK_USER" "$desktop_dir"
  sudo cp "$KIOSK_HOME/.local/share/applications/kiosk-chrome.desktop" "$desktop_dir/kiosk-chrome.desktop"
  sudo chmod 755 "$desktop_dir/kiosk-chrome.desktop"

  sudo chown "$KIOSK_USER:$KIOSK_USER" \
    "$KIOSK_HOME/bin/kiosk.sh" \
    "$KIOSK_HOME/.local/share/applications/kiosk-chrome.desktop" \
    "$KIOSK_HOME/.config/autostart/kiosk-chrome.desktop" \
    "$desktop_dir/kiosk-chrome.desktop"
}

configure_gnome_power_settings() {
  log "GNOME-Energie- und Sperr-Einstellungen für '${KIOSK_USER}' werden gesetzt."
  sudo -u "$KIOSK_USER" HOME="$KIOSK_HOME" dbus-run-session -- bash -lc "
    gsettings set org.gnome.desktop.session idle-delay 0
    gsettings set org.gnome.desktop.screensaver lock-enabled false
    gsettings set org.gnome.desktop.lockdown disable-lock-screen true
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 0
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
  " || log "Warnung: GNOME-Settings konnten nicht vollständig gesetzt werden. Bitte in der GUI prüfen."
}

configure_chrome_policy() {
  local origin="$1"

  log "Chrome-Policy für Kamera- und Mikrofon-Freigaben wird gesetzt."
  sudo install -d -m 755 "$CHROME_POLICY_DIR"
  sudo tee "$CHROME_POLICY_FILE" >/dev/null <<EOF
{
  "AudioCaptureAllowedUrls": [
    "${origin}",
    "${origin}/*"
  ],
  "VideoCaptureAllowedUrls": [
    "${origin}",
    "${origin}/*"
  ]
}
EOF
}

configure_poweroff_timer() {
  local poweroff_time="$1"

  if [[ -z "$poweroff_time" ]]; then
    log "Kein Ausschalt-Timer konfiguriert."
    if systemctl list-unit-files kiosk-poweroff.timer >/dev/null 2>&1; then
      sudo systemctl disable --now kiosk-poweroff.timer >/dev/null 2>&1 || true
    fi
    sudo rm -f "$POWEROFF_SERVICE" "$POWEROFF_TIMER"
    sudo systemctl daemon-reload
    return 0
  fi

  log "Täglicher Ausschalt-Timer für ${poweroff_time} wird eingerichtet."
  sudo tee "$POWEROFF_SERVICE" >/dev/null <<EOF
[Unit]
Description=Kiosk poweroff

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl poweroff
EOF

  sudo tee "$POWEROFF_TIMER" >/dev/null <<EOF
[Unit]
Description=Power off kiosk daily at ${poweroff_time}

[Timer]
OnCalendar=*-*-* ${poweroff_time}:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now kiosk-poweroff.timer
}

main() {
  local base_url
  local token
  local poweroff_time
  local full_url
  local origin
  local current_user
  local masked_url

  ensure_not_root
  ensure_supported_os
  require_command python3
  current_user="$(id -un)"

  log "Setup startet unter Benutzer '${current_user}'."
  if [[ "$current_user" != "vplan" ]]; then
    log "Hinweis: Die README ist auf den Aufruf als Benutzer 'vplan' ausgelegt."
  fi

  base_url="$(prompt_url)"
  token="$(prompt_nonempty 'Token: ')"
  poweroff_time="$(prompt_poweroff_time)"

  full_url="${base_url%#}#${token}"
  masked_url="${base_url%#}#***"
  origin="$(python3 - "$base_url" <<'PY'
import sys
from urllib.parse import urlsplit

parts = urlsplit(sys.argv[1])
if not parts.scheme or not parts.netloc:
    raise SystemExit("URL konnte nicht geparst werden.")
print(f"{parts.scheme}://{parts.netloc}")
PY
)"

  log "Verwendete Kiosk-URL: ${masked_url}"
  ensure_sudo_session
  install_packages
  ensure_kiosk_user
  configure_gdm_autologin
  configure_kiosk_files "$full_url" "$origin"
  configure_gnome_power_settings
  configure_chrome_policy "$origin"
  configure_poweroff_timer "$poweroff_time"

  log "Fertig."
  printf '\n'
  printf 'Benutzer: %s\n' "$current_user"
  printf 'Kiosk-Benutzer: %s\n' "$KIOSK_USER"
  printf 'Kiosk-URL: %s\n' "$masked_url"
  if [[ -n "$poweroff_time" ]]; then
    printf 'Ausschaltzeit: %s\n' "$poweroff_time"
  else
    printf 'Ausschaltzeit: deaktiviert\n'
  fi
  printf '\n'
  printf 'Empfohlen: System jetzt neu starten, damit Autologin und Autostart sauber greifen.\n'
}

main "$@"
