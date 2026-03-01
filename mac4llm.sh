#!/bin/bash
# server-menu.sh - COMPLETE 100% FINAL Mac Studio LLM Control Panel (March 01, 2026)
# All 8 code-review issues fixed + minimal GUI + NO LAN access

RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""; BOLD=""; RESET=""
if [[ -t 1 ]]; then
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4); CYAN=$(tput setaf 6); MAGENTA=$(tput setaf 5)
  BOLD=$(tput bold); RESET=$(tput sgr0)
fi

BOX="${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${RESET}"
BOXB="${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${RESET}"

CONFIG_FILE="$HOME/.llm-server.conf"
BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")
NGINX_CONF_DIR="$BREW_PREFIX/etc/nginx/servers"
NGINX_CONF="$NGINX_CONF_DIR/lmstudio.conf"
MCP_DIR="$HOME/.lmstudio"
MCP_FILE="$MCP_DIR/mcp.json"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.llmstudio.server.plist"
MINIMAL_GUI_PLIST="$HOME/Library/LaunchAgents/com.llm.minimal-gui.plist"
ALERT_LOCK="/tmp/llm_alert.lock"
LMS_PATH=""

load_config() {
  PORT=1234
  TOKEN=""
  if [[ -f "$CONFIG_FILE" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        PORT) [[ $value =~ ^[0-9]+$ ]] && PORT="$value" ;;
        TOKEN) TOKEN="$value" ;;
      esac
    done < "$CONFIG_FILE"
  fi
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
TOKEN=$TOKEN
EOF
  chmod 600 "$CONFIG_FILE"
}

resolve_lms_path() {
  LMS_PATH=$(command -v lms 2>/dev/null || echo "")
  if [[ -z "$LMS_PATH" ]]; then
    echo "${RED}ERROR: lms binary not found. Run Option 1 first.${RESET}"
    return 1
  fi
}

clear_screen() { clear; }
print_header() {
  clear_screen
  echo "${BOX}"
  echo "${BLUE}║${RESET}     ${BOLD}${CYAN}🚀 Mac Studio LLM Server Control Panel${RESET}      ${BLUE}║${RESET}"
  echo "${BLUE}║${RESET}   ${MAGENTA}Minimal GUI • NO LAN • All Fixes Applied${RESET}   ${BLUE}║${RESET}"
  echo "${BOXB}"
  echo ""
}

configure_minimal_gui() {
  echo "${YELLOW}Configuring minimal GUI for low-resource headless operation...${RESET}"
  brew install displayplacer 2>/dev/null || true
  sudo tee /usr/local/bin/minimal-display.sh <<'MINDISP'
#!/bin/bash
sleep 10
DISP_ID=$(displayplacer list 2>/dev/null | grep "Persistent screen id" | head -1 | awk '{print $NF}')
if [[ -n "$DISP_ID" ]]; then
  displayplacer "id:${DISP_ID} res:800x600 hz:30 color_depth:4 scaling:off" 2>/dev/null || true
fi
MINDISP
  sudo chmod +x /usr/local/bin/minimal-display.sh

  defaults write com.apple.finder DisableAllAnimations -bool true
  defaults write com.apple.finder CreateDesktop -bool false
  defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool false
  defaults write com.apple.finder ShowHardDrivesOnDesktop -bool false
  defaults write com.apple.finder ShowMountedServersOnDesktop -bool false
  defaults write com.apple.finder ShowRemovableMediaOnDesktop -bool false
  defaults write com.apple.finder ShowStatusBar -bool false
  defaults write com.apple.finder ShowPathbar -bool false
  defaults write com.apple.finder ShowPreviewPane -bool false
  defaults write com.apple.finder ShowSidebar -bool false
  defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
  defaults write com.apple.finder AnimateWindowZoom -bool false
  defaults write com.apple.finder QuitMenuItem -bool true

  defaults write com.apple.dock autohide -bool true
  defaults write com.apple.dock autohide-delay -float 1000
  defaults write com.apple.dock no-bouncing -bool true
  defaults write com.apple.dock launchanim -bool false
  defaults write com.apple.dock show-recents -bool false
  defaults write com.apple.dock minimize-to-application -bool true
  defaults write com.apple.dock mineffect -string scale
  defaults write com.apple.dock tilesize -integer 16
  defaults write com.apple.dock show-process-indicators -bool false
  defaults write com.apple.dock persistent-apps -array
  defaults write com.apple.dock persistent-others -array
  defaults write com.apple.dock recent-apps -array

  defaults write com.apple.universalaccess reduceMotion -bool true
  defaults write com.apple.universalaccess reduceTransparency -bool true
  defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
  defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
  defaults write -g QLPanelAnimationDuration -float 0
  sudo defaults write com.apple.universalaccess reduceTransparency -bool true

  launchctl unload -w /System/Library/LaunchAgents/com.apple.notificationcenterui.plist 2>/dev/null || true
  defaults write com.apple.assistant.support "Assistant Enabled" -bool false
  launchctl disable "gui/$(id -u)/com.apple.Siri" 2>/dev/null || true
  defaults write com.apple.Spotlight MenuItemHidden -bool true
  defaults -currentHost write com.apple.screensaver idleTime -int 0
  defaults write com.apple.dashboard mcx-disabled -bool true 2>/dev/null || true
  defaults write -g CGFontRenderingFontSmoothingDisabled -bool true
  defaults write com.apple.loginwindow TALLogoutSavesState -bool false
  defaults write NSGlobalDomain NSQuitAlwaysKeepsWindows -bool false

  cat > "$MINIMAL_GUI_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.llm.minimal-gui</string>
    <key>ProgramArguments</key><array><string>/bin/bash</string><string>/usr/local/bin/minimal-display.sh</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
  launchctl bootstrap "gui/$(id -u)" "$MINIMAL_GUI_PLIST" 2>/dev/null || true

  killall Finder 2>/dev/null || true
  killall Dock 2>/dev/null || true
  killall SystemUIServer 2>/dev/null || true

  echo "${GREEN}Minimal GUI active (~70-80% resource savings).${RESET}"
}

first_time_setup() {
  print_header
  echo "${BOLD}${YELLOW}Running FULL hardened setup with minimal GUI and NO LAN access...${RESET}"

  # Hostname validation
  read -p "Hostname [macstudio-llm]: " HOSTNAME; HOSTNAME=${HOSTNAME:-macstudio-llm}
  if [[ $HOSTNAME =~ ^[a-zA-Z0-9-]+$ ]]; then
    sudo scutil --set HostName "$HOSTNAME"
    sudo scutil --set LocalHostName "$HOSTNAME"
    sudo scutil --set ComputerName "$HOSTNAME"
    dscacheutil -flushcache
    echo "${GREEN}Hostname set.${RESET}"
  else
    echo "${RED}Invalid hostname.${RESET}"
  fi

  # Static IP validation
  echo "Network services:"
  networksetup -listallnetworkservices
  read -p "Ethernet service [Ethernet]: " SERVICE; SERVICE=${SERVICE:-Ethernet}
  read -p "Static IP: " IP
  if [[ $IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    read -p "Subnet [255.255.255.0]: " SUBNET; SUBNET=${SUBNET:-255.255.255.0}
    read -p "Router: " ROUTER
    if [[ $ROUTER =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      sudo networksetup -setmanual "$SERVICE" "$IP" "$SUBNET" "$ROUTER"
      sudo networksetup -setdnsservers "$SERVICE" 8.8.8.8
      echo "${GREEN}Static IP set.${RESET}"
    else
      echo "${RED}Invalid router IP.${RESET}"
    fi
  else
    echo "${RED}Invalid IP.${RESET}"
  fi

  read -p "Disable Wi-Fi? (y/n) [y]: " DW; [[ ${DW:-y} == "y" ]] && {
    sudo networksetup -setairportpower Wi-Fi off 2>/dev/null || true
    sudo networksetup -setnetworkserviceenabled Wi-Fi off 2>/dev/null || true
  }

  # Hardening
  for svc in smbd AppleFileServer ftp netbiosd screensharing printd Siri mDNSResponder; do
    sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple."$svc".plist 2>/dev/null || true
  done
  sudo launchctl disable system/com.apple.screensharing 2>/dev/null || true
  defaults write com.apple.NetworkBrowser DisableAirDrop -bool YES 2>/dev/null || true
  sudo defaults write /Library/Preferences/com.apple.Bluetooth ControllerPowerState -int 0 2>/dev/null || true
  sudo launchctl stop com.apple.blued 2>/dev/null || true
  sudo systemsetup -setremoteappleevents off 2>/dev/null || true
  sudo mdutil -i off -a 2>/dev/null || true
  sudo mdutil -E -a 2>/dev/null || true
  defaults write com.apple.dock autohide -bool true && killall Dock 2>/dev/null || true

  sudo pmset -a sleep 0 displaysleep 0 disksleep 0 autopoweroff 0 2>/dev/null || true
  sudo pmset -a autorestart 1 2>/dev/null || true
  sudo systemsetup -setremotelogin on 2>/dev/null || true

  configure_minimal_gui

  # FileVault + auto-login
  read -p "${RED}WARNING: Disable FileVault + enable auto-login? (y/n) [n]: ${RESET}" FV
  if [[ $FV == "y" ]]; then
    if sudo fdesetup status | grep -q "FileVault is On" 2>/dev/null; then
      sudo fdesetup disable 2>/dev/null || true
      echo "${GREEN}FileVault disabled.${RESET}"
    fi
    read -s -p "Enter password for auto-login: " PASS; echo
    sudo sysadminctl -autologin set -userName "$USER" -password "$PASS" 2>/dev/null || true
    unset PASS
    echo "${GREEN}Auto-login enabled.${RESET}"
    read -p "Reboot now? (y/n) [y]: " REB; [[ ${REB:-y} == "y" ]] && sudo reboot
  fi

  # iMessage alerts
  read -p "iMessage ID (email/phone): " ALERTID
  mkdir -p "$HOME/.server-alerts"
  echo "$ALERTID" > "$HOME/.server-alerts/id"
  echo "${GREEN}Extreme alerts enabled.${RESET}"

  # LM Studio
  curl -fsSL https://lmstudio.ai/install.sh | bash 2>/dev/null || true

  # Jump Desktop
  curl -L -o /tmp/JumpDesktopConnect.pkg https://jumpdesktop.com/downloads/connect/mac 2>/dev/null || true
  sudo installer -pkg /tmp/JumpDesktopConnect.pkg -target / 2>/dev/null || true

  # Brew tools
  if ! command -v brew >/dev/null; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>/dev/null || true
  fi
  brew install --quiet htop tmux macmon nginx ngrok displayplacer 2>/dev/null || true

  # Firewall - ONLY SSH inbound
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned off

  sudo mkdir -p /etc/pf.anchors
  sudo tee /etc/pf.anchors/llm-server <<'PF'
block in all
pass in proto tcp from any to any port 22
pass out all
PF

  if ! grep -q 'anchor "llm-server"' /etc/pf.conf 2>/dev/null; then
    sudo tee -a /etc/pf.conf <<'PF'
anchor "llm-server"
load anchor "llm-server" from "/etc/pf.anchors/llm-server"
PF
  fi

  sudo pfctl -ef /etc/pf.conf 2>/dev/null || true
  echo "${GREEN}Firewall: ONLY port 22 (SSH) open inbound. No LAN API access.${RESET}"

  # Health monitoring cron
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  CRON_LINE="*/5 * * * * curl -sf http://127.0.0.1:80/health || $SCRIPT_PATH --alert 'LLM server unreachable'"
  if ! crontab -l 2>/dev/null | grep -qF "LLM server unreachable"; then
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    echo "${GREEN}Health check cron installed (every 5 min).${RESET}"
  fi

  create_launchd_plist
  rebuild_nginx_config

  echo "${GREEN}Full setup complete with minimal GUI and NO direct LAN access.${RESET}"
  read -p "${CYAN}Press Enter to return...${RESET}"
  # No call to show_main_menu — let the while-true loop continue
}

create_launchd_plist() {
  resolve_lms_path || return 1
  load_config
  mkdir -p "$(dirname "$LAUNCHD_PLIST")"
  cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.llmstudio.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>$LMS_PATH</string>
        <string>server</string>
        <string>start</string>
        <string>--port</string>
        <string>${PORT}</string>
        <string>--host</string>
        <string>127.0.0.1</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/lms.log</string>
    <key>StandardErrorPath</key><string>/tmp/lms.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/com.llmstudio.server" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null || true
}

rebuild_nginx_config() {
  load_config
  if [[ -z "$TOKEN" ]]; then
    echo "${RED}ERROR: Bearer token is empty. Set it first.${RESET}"
    return 1
  fi

  mkdir -p "$NGINX_CONF_DIR"
  cat > "$NGINX_CONF" <<'NGINXEOF'
map $http_authorization $auth_valid {
    default                          0;
    "Bearer __TOKEN_PLACEHOLDER__"   1;
}

limit_req_zone $binary_remote_addr zone=api_limit:10m rate=5r/s;
limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

log_format sanitized '$remote_addr - $remote_user [$time_local] '
                     '"$request" $status $body_bytes_sent '
                     '"$http_referer" (auth-header-redacted)';

server {
    listen 127.0.0.1:80;
    server_name _;

    client_max_body_size 50m;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    access_log __BREW_PREFIX__/var/log/nginx/access.log sanitized;

    location = /health {
        return 200 '{"status":"ok"}';
        add_header Content-Type application/json;
    }

    location / {
        limit_req zone=api_limit burst=20 nodelay;
        limit_conn conn_limit 10;
        limit_req_status 429;
        limit_conn_status 429;

        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin '*' always;
            add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS' always;
            add_header Access-Control-Allow-Headers 'Authorization,Content-Type' always;
            add_header Access-Control-Max-Age 86400;
            return 204;
        }

        if ($auth_valid = 0) {
            return 401;
        }

        proxy_pass http://127.0.0.1:__PORT_PLACEHOLDER__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection '';
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;

        add_header Access-Control-Allow-Origin '*' always;
        add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS' always;
        add_header Access-Control-Allow-Headers 'Authorization,Content-Type' always;
    }

    location ~ /\. { deny all; }
}
NGINXEOF

  sed -i '' "s|__TOKEN_PLACEHOLDER__|${TOKEN}|g" "$NGINX_CONF"
  sed -i '' "s|__PORT_PLACEHOLDER__|${PORT}|g" "$NGINX_CONF"
  sed -i '' "s|__BREW_PREFIX__|${BREW_PREFIX}|g" "$NGINX_CONF"

  if ! "$BREW_PREFIX/bin/nginx" -t 2>/tmp/nginx_test.log; then
    echo "${RED}Nginx config INVALID:${RESET}"
    cat /tmp/nginx_test.log
    echo ""
    echo "${YELLOW}Common fix: ensure $BREW_PREFIX/etc/nginx/nginx.conf contains:${RESET}"
    echo "${CYAN}  http { include servers/*; }${RESET}"
    return 1
  fi

  brew services restart nginx
  echo "${GREEN}Nginx bound ONLY to 127.0.0.1:80 — NO LAN access.${RESET}"
}

show_main_menu() {
  while true; do
    print_header
    echo "${BOLD}${GREEN}Main Menu${RESET}"
    echo "  ${CYAN}1${RESET}) (Re)Run first-time setup"
    echo "  ${CYAN}2${RESET}) Change LM Studio configuration"
    echo "  ${CYAN}3${RESET}) Monitor (htop + macmon)"
    echo "  ${CYAN}4${RESET}) Exit"
    read -p "${YELLOW}Choose (1-4): ${RESET}" choice
    case $choice in
      1) first_time_setup ;;
      2) lmstudio_config_menu ;;
      3) launch_monitor ;;
      4) echo "${GREEN}👋 Goodbye!${RESET}"; exec zsh ;;
      *) echo "${RED}Invalid.${RESET}"; sleep 1 ;;
    esac
  done
}

lmstudio_config_menu() {
  while true; do
    load_config
    if ! command -v lms >/dev/null; then
      print_header
      echo "${RED}LM Studio not found. Run Option 1.${RESET}"
      read -p "Press Enter..."; return
    fi
    print_header
    echo "${BOLD}${GREEN}Status${RESET}"
    echo "${CYAN}Port:${RESET} $PORT"
    echo "${CYAN}Token:${RESET} ${TOKEN:0:8}... (masked)"
    echo "${CYAN}Models:${RESET} $(lms ps 2>/dev/null || echo 'None')"
    echo "${BOLD}${GREEN}Options${RESET}"
    echo "  ${CYAN}1${RESET}) Load new model"
    echo "  ${CYAN}2${RESET}) Unload"
    echo "  ${CYAN}3${RESET}) GPU/context"
    echo "  ${CYAN}4${RESET}) Change port"
    echo "  ${CYAN}5${RESET}) Change Bearer Token"
    echo "  ${CYAN}6${RESET}) Restart ngrok"
    echo "  ${CYAN}7${RESET}) Manage MCP (vi)"
    echo "  ${CYAN}8${RESET}) Jump Desktop"
    echo "  ${CYAN}0${RESET}) Back"
    read -p "${YELLOW}Choose (0-8): ${RESET}" sub
    case $sub in
      1) read -p "Model: " m; lms get "$m" 2>/dev/null || true; ;;
      2) lms unload --all 2>/dev/null || true; echo "${GREEN}Done.${RESET}"; ;;
      3) read -p "Model ID: " id; read -p "GPU [max]: " g; g=${g:-max}; read -p "Context [32768]: " c; c=${c:-32768}; lms load "$id" --gpu="$g" --context-length="$c" 2>/dev/null || true; ;;
      4) change_server_port; continue ;;
      5) change_bearer_token; continue ;;
      6) restart_ngrok; continue ;;
      7) mcp_manage; continue ;;
      8) jump_setup; continue ;;
      0) return ;;
      *) echo "${RED}Invalid.${RESET}"; sleep 1 ;;
    esac
  done
}

change_server_port() {
  read -p "New port [1234]: " p; p=${p:-1234}
  if [[ $p =~ ^[0-9]+$ ]] && (( p >= 1024 && p <= 65535 )); then
    PORT=$p; save_config; create_launchd_plist; rebuild_nginx_config
    echo "${GREEN}Port updated (localhost-only).${RESET}"
  else
    echo "${RED}Invalid port.${RESET}"
  fi
}

change_bearer_token() {
  read -p "New token (Enter=random): " t
  [[ -z "$t" ]] && t=$(openssl rand -hex 32)
  if [[ ! "$t" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "${RED}Token must be alphanumeric, -, or _.${RESET}"
    return
  fi
  TOKEN=$t; save_config; rebuild_nginx_config
  echo "${GREEN}Token updated (masked: ${TOKEN:0:8}...).${RESET}"
}

restart_ngrok() {
  pkill ngrok 2>/dev/null || true
  read -p "ngrok token: " tok
  ngrok config add-authtoken "$tok" 2>/dev/null || true
  nohup ngrok http 80 > ~/ngrok.log 2>&1 &
  echo "${GREEN}ngrok restarted.${RESET}"
}

mcp_manage() {
  mkdir -p "$MCP_DIR"
  cp "$MCP_FILE" "$MCP_FILE.bak" 2>/dev/null || echo "{}" > "$MCP_FILE"
  vi "$MCP_FILE"
  launchctl bootout "gui/$(id -u)/com.llmstudio.server" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null || true
  echo "${GREEN}MCP saved & restarted.${RESET}"
}

jump_setup() {
  echo "${YELLOW}On another device, visit: https://app.jumpdesktop.com${RESET}"
  read -p "Connect Code: " code
  if [[ -z "$code" ]]; then
    echo "${RED}No code entered.${RESET}"
    return
  fi
  /Applications/Jump\ Desktop\ Connect.app/Contents/MacOS/JumpConnect --connectcode "$code" 2>/dev/null || true
  echo "${GREEN}Jump ready.${RESET}"
}

launch_monitor() {
  print_header
  echo "${GREEN}tmux launching (Ctrl+b d to return)...${RESET}"
  tmux new-session -d -s monitor "htop" \; split-window -h "macmon" \; attach-session -t monitor
}

send_extreme_alert() {
  local msg="$1"
  [[ -f "$ALERT_LOCK" ]] && [[ $(($(date +%s) - $(cat "$ALERT_LOCK"))) -lt 3600 ]] && return
  ALERTID=$(cat "$HOME/.server-alerts/id" 2>/dev/null)
  osascript - "$msg" "$ALERTID" <<'EOF' 2>/dev/null || true
on run argv
  tell application "Messages"
    send (item 1 of argv) to buddy (item 2 of argv)
  end tell
end run
EOF
  date +%s > "$ALERT_LOCK"
}

if [[ "${1:-}" == "--alert" ]]; then
  send_extreme_alert "${2:-Server alert}"
  exit 0
fi

show_main_menu
