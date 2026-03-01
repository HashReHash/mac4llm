#!/bin/bash
# mac4llm.sh — Mac Studio LLM Control Panel (March 2026)
# All bugs fixed. Every step: skip, retry, error recovery.

# ── Colors (safe for non-interactive / cron) ──
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""; BOLD=""; RESET=""
if [[ -t 1 ]]; then
  RED=$(tput setaf 1 2>/dev/null) || RED=""
  GREEN=$(tput setaf 2 2>/dev/null) || GREEN=""
  YELLOW=$(tput setaf 3 2>/dev/null) || YELLOW=""
  BLUE=$(tput setaf 4 2>/dev/null) || BLUE=""
  CYAN=$(tput setaf 6 2>/dev/null) || CYAN=""
  MAGENTA=$(tput setaf 5 2>/dev/null) || MAGENTA=""
  BOLD=$(tput bold 2>/dev/null) || BOLD=""
  RESET=$(tput sgr0 2>/dev/null) || RESET=""
fi

# ── Paths ──
CONFIG_FILE="$HOME/.llm-server.conf"
BREW_PREFIX=""
NGINX_CONF_DIR=""
NGINX_CONF=""
MCP_DIR="$HOME/.lmstudio"
MCP_FILE="$MCP_DIR/mcp.json"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.llmstudio.server.plist"
MINIMAL_GUI_PLIST="$HOME/Library/LaunchAgents/com.llm.minimal-gui.plist"
ALERT_LOCK="/tmp/llm_alert.lock"
LMS_PATH=""
DIVIDER="${BLUE}──────────────────────────────────────────────────────────────${RESET}"

detect_brew_prefix() {
  BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")
  NGINX_CONF_DIR="$BREW_PREFIX/etc/nginx/servers"
  NGINX_CONF="$NGINX_CONF_DIR/lmstudio.conf"
}
detect_brew_prefix

# ── Config (safe parsing, no source) ──
load_config() {
  PORT=1234; TOKEN=""
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

# ── UI Helpers ──
clear_screen() { clear 2>/dev/null || true; }

print_header() {
  clear_screen
  echo "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo "${BLUE}║  ${BOLD}${CYAN}Mac Studio LLM Server Control Panel${RESET}                       ${BLUE}║${RESET}"
  echo "${BLUE}║  ${MAGENTA}Follow steps to fine-tune your Mac to run LM Studio${RESET}       ${BLUE}║${RESET}"
  echo "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

step_ok() {
  echo "${GREEN}✅ $1${RESET}"
  echo "$DIVIDER"
}

# Returns via global: STEP_ACTION = skip | retry | menu | exit
step_fail() {
  echo "${RED}❌ $1${RESET}"
  echo ""
  echo "  ${CYAN}1${RESET}) Retry this step"
  echo "  ${CYAN}2${RESET}) Skip to next step"
  echo "  ${CYAN}3${RESET}) Return to main menu"
  echo "  ${CYAN}4${RESET}) Exit script"
  read -p "${YELLOW}Choose [2]: ${RESET}" FAILCHOICE
  case "${FAILCHOICE:-2}" in
    1) STEP_ACTION="retry" ;;
    2) STEP_ACTION="skip" ;;
    3) STEP_ACTION="menu" ;;
    4) echo "${GREEN}👋 Goodbye!${RESET}"; exit 0 ;;
    *) STEP_ACTION="skip" ;;
  esac
}

# Usage after step_fail:
#   step_fail "msg"
#   [[ $STEP_ACTION == "retry" ]] && continue
#   [[ $STEP_ACTION == "menu" ]] && return
#   break  # skip

# ── Minimal GUI ──
configure_minimal_gui() {
  echo "${BOLD}${YELLOW}Step: Configure minimal GUI${RESET}"

  sudo mkdir -p /usr/local/bin
  mkdir -p "$HOME/Library/LaunchAgents"

  sudo tee /usr/local/bin/minimal-display.sh > /dev/null <<'MINDISP'
#!/bin/bash
sleep 10
DISP_ID=$(displayplacer list 2>/dev/null | grep "Persistent screen id" | head -1 | awk '{print $NF}')
if [[ -n "$DISP_ID" ]]; then
  displayplacer "id:${DISP_ID} res:800x600 hz:30 color_depth:4 scaling:off" 2>/dev/null || true
fi
MINDISP
  sudo chmod +x /usr/local/bin/minimal-display.sh

  {
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
  } >/dev/null 2>&1

  cat > "$MINIMAL_GUI_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.llm.minimal-gui</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/usr/local/bin/minimal-display.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/com.llm.minimal-gui" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$MINIMAL_GUI_PLIST" 2>/dev/null || true

  {
    killall Finder
    killall Dock
    killall SystemUIServer
  } >/dev/null 2>&1 || true

  step_ok "Minimal GUI configured"
}

# ══════════════════════════════════════════════════════════════
# FIRST TIME SETUP
# ══════════════════════════════════════════════════════════════
first_time_setup() {
  print_header
  echo "${BOLD}${YELLOW}(Re)configuring your Mac for LLM...${RESET}"
  echo "$DIVIDER"

  # ── STEP: Hostname ──
  while true; do
    echo "${BOLD}${YELLOW}Step: Set hostname${RESET}"
    echo "  ${CYAN}1${RESET}) Set custom hostname"
    echo "  ${CYAN}2${RESET}) Skip"
    read -p "${YELLOW}Choose [1]: ${RESET}" HCHOICE
    if [[ "${HCHOICE:-1}" == "2" ]]; then
      echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"; break
    fi
    read -p "Hostname [macstudio-llm]: " HOSTNAME
    HOSTNAME=${HOSTNAME:-macstudio-llm}
    # No leading/trailing hyphens, alphanumeric + hyphens only
    if [[ $HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
      sudo scutil --set HostName "$HOSTNAME"
      sudo scutil --set LocalHostName "$HOSTNAME"
      sudo scutil --set ComputerName "$HOSTNAME"
      dscacheutil -flushcache
      step_ok "Hostname set to $HOSTNAME"
      break
    else
      step_fail "Invalid hostname — letters, numbers, hyphens only, no leading/trailing hyphen"
      [[ $STEP_ACTION == "retry" ]] && continue
      [[ $STEP_ACTION == "menu" ]] && return
      break
    fi
  done

  # ── STEP: Static IP ──
  while true; do
    echo "${BOLD}${YELLOW}Step: Set static IP${RESET}"

    # Parse interfaces (compatible with bash 3.2 — no mapfile)
    local IFACES=()
    while IFS= read -r line; do
      IFACES+=("$line")
    done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)

    if [[ ${#IFACES[@]} -eq 0 ]]; then
      step_fail "No network interfaces found"
      [[ $STEP_ACTION == "menu" ]] && return
      break
    fi

    local i
    for i in "${!IFACES[@]}"; do
      echo "  ${CYAN}$((i+1))${RESET}) ${IFACES[$i]}"
    done
    local SKIP_NUM=$(( ${#IFACES[@]} + 1 ))
    echo "  ${CYAN}${SKIP_NUM}${RESET}) Skip this step"
    read -p "Select interface for static IP [1]: " NUM
    NUM=${NUM:-1}

    if [[ "$NUM" == "$SKIP_NUM" ]]; then
      echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"; break
    fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || (( NUM < 1 || NUM > ${#IFACES[@]} )); then
      step_fail "Invalid selection"
      [[ $STEP_ACTION == "retry" ]] && continue
      [[ $STEP_ACTION == "menu" ]] && return
      break
    fi

    local SERVICE="${IFACES[$((NUM-1))]}"
    read -p "Static IP: " IP
    if [[ ! $IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      step_fail "Invalid IP address format"
      [[ $STEP_ACTION == "retry" ]] && continue
      [[ $STEP_ACTION == "menu" ]] && return
      break
    fi
    read -p "Subnet mask [255.255.255.0]: " SUBNET
    SUBNET=${SUBNET:-255.255.255.0}
    read -p "Router/Gateway IP: " ROUTER
    if [[ ! $ROUTER =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      step_fail "Invalid router IP format"
      [[ $STEP_ACTION == "retry" ]] && continue
      [[ $STEP_ACTION == "menu" ]] && return
      break
    fi
    if sudo networksetup -setmanual "$SERVICE" "$IP" "$SUBNET" "$ROUTER" 2>/dev/null; then
      sudo networksetup -setdnsservers "$SERVICE" 8.8.8.8 2>/dev/null
      step_ok "Static IP $IP set on $SERVICE"
      break
    else
      step_fail "Failed to set static IP on $SERVICE"
      [[ $STEP_ACTION == "retry" ]] && continue
      [[ $STEP_ACTION == "menu" ]] && return
      break
    fi
  done

  # ── STEP: Disable Wi-Fi ──
  echo "${BOLD}${YELLOW}Step: Disable Wi-Fi${RESET}"
  echo "  ${CYAN}1${RESET}) Yes — disable Wi-Fi (recommended for server)"
  echo "  ${CYAN}2${RESET}) No — keep Wi-Fi enabled"
  echo "  ${CYAN}3${RESET}) Skip"
  read -p "${YELLOW}Choose [1]: ${RESET}" DWNUM
  case "${DWNUM:-1}" in
    1)
      # Detect actual Wi-Fi device name from hardware ports
      local WIFI_DEV=""
      local in_wifi=false
      while IFS= read -r line; do
        if echo "$line" | grep -qi "Wi-Fi\|AirPort"; then
          in_wifi=true
        elif [[ $in_wifi == true ]] && echo "$line" | grep -q "^Device:"; then
          WIFI_DEV=$(echo "$line" | awk '{print $2}')
          break
        elif echo "$line" | grep -q "^Hardware Port:"; then
          in_wifi=false
        fi
      done < <(networksetup -listallhardwareports 2>/dev/null)

      if [[ -n "$WIFI_DEV" ]]; then
        sudo networksetup -setairportpower "$WIFI_DEV" off >/dev/null 2>&1 || true
        step_ok "Wi-Fi disabled (device: $WIFI_DEV)"
      else
        echo "${YELLOW}No Wi-Fi hardware detected — nothing to disable.${RESET}"
        echo "$DIVIDER"
      fi
      ;;
    2) echo "${GREEN}Wi-Fi left enabled.${RESET}"; echo "$DIVIDER" ;;
    3) echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER" ;;
  esac

  # ── STEP: System hardening ──
  echo "${BOLD}${YELLOW}Step: System hardening${RESET}"
  echo "  ${CYAN}1${RESET}) Apply (disable unused services, never-sleep, enable SSH)"
  echo "  ${CYAN}2${RESET}) Skip"
  read -p "${YELLOW}Choose [1]: ${RESET}" HARDEN
  if [[ "${HARDEN:-1}" == "1" ]]; then
    {
      for svc in smbd AppleFileServer ftp netbiosd screensharing printd Siri mDNSResponder; do
        sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple."$svc".plist 2>/dev/null || true
      done
      sudo launchctl disable system/com.apple.screensharing
      defaults write com.apple.NetworkBrowser DisableAirDrop -bool YES
      sudo defaults write /Library/Preferences/com.apple.Bluetooth ControllerPowerState -int 0
      sudo launchctl stop com.apple.blued
      sudo systemsetup -setremoteappleevents off
      sudo mdutil -i off -a
      sudo mdutil -E -a
      sudo pmset -a sleep 0 displaysleep 0 disksleep 0 autopoweroff 0
      sudo pmset -a autorestart 1
      sudo systemsetup -setremotelogin on
    } >/dev/null 2>&1
    step_ok "System hardened (services disabled, never-sleep, SSH on)"
  else
    echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"
  fi

  # ── STEP: Minimal GUI ──
  echo "${BOLD}${YELLOW}Step: Minimal GUI${RESET}"
  echo "  ${CYAN}1${RESET}) Configure minimal GUI (saves ~2GB RAM)"
  echo "  ${CYAN}2${RESET}) Skip"
  read -p "${YELLOW}Choose [1]: ${RESET}" MGUI
  if [[ "${MGUI:-1}" == "1" ]]; then
    configure_minimal_gui
  else
    echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"
  fi

  # ── STEP: FileVault + Auto-login ──
  echo "${BOLD}${YELLOW}Step: FileVault & auto-login${RESET}"
  echo "  ${CYAN}1${RESET}) Disable FileVault + enable auto-login (for headless server)"
  echo "  ${CYAN}2${RESET}) Skip (keep current settings)"
  read -p "${YELLOW}Choose [2]: ${RESET}" FVNUM
  if [[ "$FVNUM" == "1" ]]; then
    # FileVault
    local FV_STATUS
    FV_STATUS=$(sudo fdesetup status 2>/dev/null || echo "unknown")
    echo "  Current: $FV_STATUS"

    if echo "$FV_STATUS" | grep -q "FileVault is On"; then
      echo "${YELLOW}Your login password is required to disable FileVault.${RESET}"
      read -s -p "Login password: " FV_PASS; echo

      # Create temp plist with restrictive permissions + trap cleanup
      local FV_PLIST
      FV_PLIST=$(mktemp /tmp/fv_XXXXXX.plist)
      chmod 600 "$FV_PLIST"
      trap "rm -f '$FV_PLIST' 2>/dev/null" EXIT

      cat > "$FV_PLIST" <<FVEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Username</key><string>$USER</string>
    <key>Password</key><string>$FV_PASS</string>
</dict>
</plist>
FVEOF
      if sudo fdesetup disable -inputplist < "$FV_PLIST" 2>/dev/null; then
        step_ok "FileVault disabled (decryption continues in background)"
      else
        step_fail "FileVault disable failed — wrong password?"
        [[ $STEP_ACTION == "menu" ]] && { rm -f "$FV_PLIST"; unset FV_PASS; return; }
      fi
      rm -f "$FV_PLIST"
      unset FV_PASS
      trap - EXIT
    else
      echo "${GREEN}FileVault is already off.${RESET}"; echo "$DIVIDER"
    fi

    # Auto-login
    echo "${BOLD}${YELLOW}Step: Enable auto-login${RESET}"
    read -s -p "Login password for auto-login: " AL_PASS; echo
    if [[ -n "$AL_PASS" ]]; then
      # Primary method
      sudo sysadminctl -autologin set -userName "$USER" -password "$AL_PASS" >/dev/null 2>&1
      # Fallback: write loginwindow preference directly
      sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$USER" 2>/dev/null || true
      # Disable login password requirement as additional fallback
      sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUserScreenLocked -bool false 2>/dev/null || true
      unset AL_PASS
      step_ok "Auto-login configured for $USER"
    else
      echo "${RED}Empty password — skipping auto-login.${RESET}"; echo "$DIVIDER"
    fi

    echo "  ${CYAN}1${RESET}) Reboot now (needed for changes to take effect)"
    echo "  ${CYAN}2${RESET}) Continue setup, reboot later"
    read -p "${YELLOW}Choose [2]: ${RESET}" REB
    [[ "$REB" == "1" ]] && sudo reboot
  else
    echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"
  fi

  # ── STEP: Bearer token ──
  while true; do
    echo "${BOLD}${YELLOW}Step: Set API Bearer token${RESET}"
    echo "  ${CYAN}1${RESET}) Generate random token (recommended)"
    echo "  ${CYAN}2${RESET}) Enter custom token"
    echo "  ${CYAN}3${RESET}) Skip"
    read -p "${YELLOW}Choose [1]: ${RESET}" TOKCHOICE
    case "${TOKCHOICE:-1}" in
      1)
        load_config
        TOKEN=$(openssl rand -hex 32)
        save_config
        step_ok "Token generated: ${TOKEN:0:8}... (saved in ~/.llm-server.conf)"
        break
        ;;
      2)
        read -p "Enter token: " CTOKEN
        if [[ -n "$CTOKEN" ]] && [[ "$CTOKEN" =~ ^[a-zA-Z0-9_-]+$ ]]; then
          load_config; TOKEN="$CTOKEN"; save_config
          step_ok "Token set: ${TOKEN:0:8}..."
          break
        else
          step_fail "Token must be non-empty, alphanumeric, hyphens, or underscores"
          [[ $STEP_ACTION == "retry" ]] && continue
          [[ $STEP_ACTION == "menu" ]] && return
          break
        fi
        ;;
      3)
        echo "${YELLOW}Skipped. Set token later via Main Menu → 2 → 5.${RESET}"; echo "$DIVIDER"
        break
        ;;
    esac
  done

  # ── STEP: iMessage alerts ──
  echo "${BOLD}${YELLOW}Step: iMessage alerts for server health${RESET}"
  echo "  ${CYAN}1${RESET}) Configure"
  echo "  ${CYAN}2${RESET}) Skip"
  read -p "${YELLOW}Choose [2]: ${RESET}" ALERTCHOICE
  if [[ "${ALERTCHOICE:-2}" == "1" ]]; then
    read -p "iMessage ID (email or phone): " ALERTID
    if [[ -n "$ALERTID" ]]; then
      mkdir -p "$HOME/.server-alerts"
      echo "$ALERTID" > "$HOME/.server-alerts/id"
      step_ok "iMessage alerts configured for $ALERTID"
    else
      echo "${RED}Empty — skipping.${RESET}"; echo "$DIVIDER"
    fi
  else
    echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"
  fi

  # ── STEP: Install software ──
  echo "${BOLD}${YELLOW}Step: Install software (Homebrew, LM Studio, Nginx, tools)${RESET}"
  echo "  ${CYAN}1${RESET}) Install all"
  echo "  ${CYAN}2${RESET}) Skip"
  read -p "${YELLOW}Choose [1]: ${RESET}" INSTCHOICE
  if [[ "${INSTCHOICE:-1}" == "1" ]]; then
    if ! command -v brew >/dev/null 2>&1; then
      echo "${YELLOW}Installing Homebrew...${RESET}"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      # Add brew to current session PATH
      if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [[ -f /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
      # Re-detect paths now that brew is available
      detect_brew_prefix
    fi

    echo "${YELLOW}Installing CLI tools...${RESET}"
    brew install --quiet htop tmux macmon nginx ngrok displayplacer 2>/dev/null || true

    echo "${YELLOW}Installing LM Studio CLI...${RESET}"
    curl -fsSL https://lmstudio.ai/install.sh | bash 2>/dev/null || true

    echo "${YELLOW}Installing Jump Desktop Connect...${RESET}"
    curl -L -o /tmp/JumpDesktopConnect.pkg https://jumpdesktop.com/downloads/connect/mac 2>/dev/null || true
    sudo installer -pkg /tmp/JumpDesktopConnect.pkg -target / 2>/dev/null || true
    rm -f /tmp/JumpDesktopConnect.pkg

    step_ok "Software installed"
  else
    echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"
  fi

  # ── STEP: Firewall ──
  echo "${BOLD}${YELLOW}Step: Configure firewall (SSH-only inbound)${RESET}"
  echo "  ${CYAN}1${RESET}) Apply firewall rules"
  echo "  ${CYAN}2${RESET}) Skip"
  read -p "${YELLOW}Choose [1]: ${RESET}" FWCHOICE
  if [[ "${FWCHOICE:-1}" == "1" ]]; then
    {
      sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
      sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on
      sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned off
    } >/dev/null 2>&1

    sudo mkdir -p /etc/pf.anchors
    sudo tee /etc/pf.anchors/llm-server > /dev/null <<'PF'
block in all
pass in proto tcp from any to any port 22
pass out all
PF

    if ! grep -q 'anchor "llm-server"' /etc/pf.conf 2>/dev/null; then
      sudo tee -a /etc/pf.conf > /dev/null <<'PF'
anchor "llm-server"
load anchor "llm-server" from "/etc/pf.anchors/llm-server"
PF
    fi

    sudo pfctl -ef /etc/pf.conf >/dev/null 2>&1 || true
    step_ok "Firewall active — only SSH (port 22) open inbound"
  else
    echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"
  fi

  # ── STEP: Health cron ──
  local SCRIPT_PATH
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  local CRON_LINE="*/5 * * * * curl -sf http://127.0.0.1:80/health || $SCRIPT_PATH --alert 'LLM server unreachable'"
  if ! crontab -l 2>/dev/null | grep -qF "LLM server unreachable"; then
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab - 2>/dev/null
  fi

  # ── STEP: Start services ──
  echo "${BOLD}${YELLOW}Step: Start LM Studio server + Nginx${RESET}"
  echo "  ${CYAN}1${RESET}) Start now"
  echo "  ${CYAN}2${RESET}) Skip (start manually later)"
  read -p "${YELLOW}Choose [1]: ${RESET}" STARTCHOICE
  if [[ "${STARTCHOICE:-1}" == "1" ]]; then
    load_config
    if [[ -z "$TOKEN" ]]; then
      TOKEN=$(openssl rand -hex 32); save_config
      echo "${GREEN}Auto-generated token: ${TOKEN:0:8}...${RESET}"
    fi
    create_launchd_plist
    rebuild_nginx_config
  else
    echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"
  fi

  echo ""
  echo "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${RESET}"
  echo "${BOLD}${GREEN}  ✅ Setup complete! Returning to main menu.${RESET}"
  echo "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${RESET}"
  read -p "${CYAN}Press Enter to continue...${RESET}"
}

# ══════════════════════════════════════════════════════════════
# LAUNCHD + NGINX
# ══════════════════════════════════════════════════════════════
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
    echo "${RED}ERROR: Bearer token is empty. Set it first (Main Menu → 2 → 5).${RESET}"
    return 1
  fi

  detect_brew_prefix
  mkdir -p "$NGINX_CONF_DIR"
  mkdir -p "$BREW_PREFIX/var/log/nginx"

  cat > "$NGINX_CONF" <<'NGINXEOF'
map $http_authorization $auth_valid {
    default                          0;
    "Bearer __TOKEN_PLACEHOLDER__"   1;
}

limit_req_zone $binary_remote_addr zone=llm_api_limit:10m rate=5r/s;
limit_conn_zone $binary_remote_addr zone=llm_conn_limit:10m;

log_format llm_sanitized '$remote_addr - $remote_user [$time_local] '
                         '"$request" $status $body_bytes_sent '
                         '"$http_referer" (auth-redacted)';

server {
    listen 127.0.0.1:80;
    server_name _;

    client_max_body_size 50m;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;

    access_log __BREW_PREFIX__/var/log/nginx/access.log llm_sanitized;

    location = /health {
        return 200 '{"status":"ok"}';
        add_header Content-Type application/json;
    }

    location / {
        limit_req zone=llm_api_limit burst=20 nodelay;
        limit_conn llm_conn_limit 10;
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

  # Safe substitution — token never visible in ps output
  local content
  content=$(<"$NGINX_CONF")
  content="${content//__TOKEN_PLACEHOLDER__/$TOKEN}"
  content="${content//__PORT_PLACEHOLDER__/$PORT}"
  content="${content//__BREW_PREFIX__/$BREW_PREFIX}"
  printf '%s' "$content" > "$NGINX_CONF"
  chmod 600 "$NGINX_CONF"

  if ! "$BREW_PREFIX/bin/nginx" -t >/tmp/nginx_test.log 2>&1; then
    echo "${RED}Nginx config INVALID:${RESET}"
    cat /tmp/nginx_test.log
    echo ""
    echo "${YELLOW}Ensure $BREW_PREFIX/etc/nginx/nginx.conf has:${RESET}"
    echo "${CYAN}  http { include servers/*; }${RESET}"
    return 1
  fi

  brew services restart nginx >/dev/null 2>&1
  step_ok "Nginx running on 127.0.0.1:80"
}

# ══════════════════════════════════════════════════════════════
# MENUS
# ══════════════════════════════════════════════════════════════
show_main_menu() {
  while true; do
    print_header
    echo "${BOLD}${GREEN}Main Menu${RESET}"
    echo ""
    echo "  ${CYAN}1${RESET}) (Re)Run first-time setup"
    echo "  ${CYAN}2${RESET}) LM Studio configuration"
    echo "  ${CYAN}3${RESET}) Monitor (htop + macmon)"
    echo "  ${CYAN}4${RESET}) Exit"
    echo ""
    read -p "${YELLOW}Choose (1-4): ${RESET}" choice
    case $choice in
      1) first_time_setup ;;
      2) lmstudio_config_menu ;;
      3) launch_monitor ;;
      4) echo "${GREEN}👋 Goodbye!${RESET}"; return 0 ;;
      *) echo "${RED}Invalid choice.${RESET}"; sleep 1 ;;
    esac
  done
}

lmstudio_config_menu() {
  while true; do
    load_config
    if ! command -v lms >/dev/null 2>&1; then
      print_header
      echo "${RED}LM Studio not found. Run Option 1 first.${RESET}"
      read -p "Press Enter..."; return
    fi
    print_header
    echo "${BOLD}${GREEN}LM Studio Status${RESET}"
    echo "  ${CYAN}Port:${RESET}   $PORT"
    echo "  ${CYAN}Token:${RESET}  ${TOKEN:0:8}... (masked)"
    echo "  ${CYAN}Models:${RESET} $(lms ps 2>/dev/null || echo 'None loaded')"
    echo ""
    echo "${BOLD}${GREEN}Options${RESET}"
    echo "  ${CYAN}1${RESET}) Load model"
    echo "  ${CYAN}2${RESET}) Unload all models"
    echo "  ${CYAN}3${RESET}) Load with GPU/context options"
    echo "  ${CYAN}4${RESET}) Change port"
    echo "  ${CYAN}5${RESET}) Change Bearer token"
    echo "  ${CYAN}6${RESET}) Restart ngrok tunnel"
    echo "  ${CYAN}7${RESET}) Edit MCP config (vi)"
    echo "  ${CYAN}8${RESET}) Setup Jump Desktop"
    echo "  ${CYAN}0${RESET}) Back to main menu"
    echo ""
    read -p "${YELLOW}Choose (0-8): ${RESET}" sub
    case $sub in
      1) read -p "Model name or path: " m
         [[ -n "$m" ]] && { lms get "$m" 2>/dev/null || true; } ;;
      2) lms unload --all 2>/dev/null || true
         step_ok "All models unloaded" ;;
      3) read -p "Model ID: " id
         read -p "GPU layers [max]: " g; g=${g:-max}
         read -p "Context length [32768]: " c; c=${c:-32768}
         lms load "$id" --gpu="$g" --context-length="$c" 2>/dev/null || true ;;
      4) change_server_port ;;
      5) change_bearer_token ;;
      6) restart_ngrok ;;
      7) mcp_manage ;;
      8) jump_setup ;;
      0) return ;;
      *) echo "${RED}Invalid.${RESET}"; sleep 1 ;;
    esac
  done
}

change_server_port() {
  read -p "New port [1234]: " p; p=${p:-1234}
  if [[ $p =~ ^[0-9]+$ ]] && (( p >= 1024 && p <= 65535 )); then
    PORT=$p; save_config; create_launchd_plist; rebuild_nginx_config
  else
    echo "${RED}Invalid port (must be 1024-65535).${RESET}"
  fi
}

change_bearer_token() {
  echo "  ${CYAN}1${RESET}) Generate random token"
  echo "  ${CYAN}2${RESET}) Enter custom token"
  read -p "${YELLOW}Choose [1]: ${RESET}" TC
  local t=""
  case "${TC:-1}" in
    1) t=$(openssl rand -hex 32) ;;
    2) read -p "Enter token: " t ;;
  esac
  if [[ -z "$t" ]]; then
    echo "${RED}Empty token — cancelled.${RESET}"; return
  fi
  if [[ ! "$t" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "${RED}Token must be alphanumeric, hyphens, or underscores only.${RESET}"; return
  fi
  TOKEN=$t; save_config; rebuild_nginx_config
}

restart_ngrok() {
  pkill ngrok 2>/dev/null || true
  read -p "ngrok authtoken: " tok
  if [[ -z "$tok" ]]; then
    echo "${RED}No token entered.${RESET}"; return
  fi
  ngrok config add-authtoken "$tok" >/dev/null 2>&1 || true
  nohup ngrok http 80 > ~/ngrok.log 2>&1 &
  sleep 3
  local URL
  URL=$(curl -sf http://127.0.0.1:4040/api/tunnels 2>/dev/null \
    | grep -o '"public_url":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [[ -n "$URL" ]]; then
    step_ok "ngrok tunnel active: $URL"
  else
    echo "${GREEN}✅ ngrok started. Check ~/ngrok.log or http://127.0.0.1:4040 for URL.${RESET}"
    echo "$DIVIDER"
  fi
}

mcp_manage() {
  mkdir -p "$MCP_DIR"
  if [[ ! -f "$MCP_FILE" ]]; then
    echo '{}' > "$MCP_FILE"
  fi
  cp "$MCP_FILE" "$MCP_FILE.bak" 2>/dev/null || true
  vi "$MCP_FILE"
  launchctl bootout "gui/$(id -u)/com.llmstudio.server" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null || true
  step_ok "MCP config saved, LM Studio restarted"
}

jump_setup() {
  echo "${YELLOW}On another device, go to: https://app.jumpdesktop.com${RESET}"
  echo "${YELLOW}Get a Connect Code, then enter it below.${RESET}"
  read -p "Connect Code: " code
  if [[ -z "$code" ]]; then
    echo "${RED}No code entered.${RESET}"; return
  fi
  if [[ -f "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect" ]]; then
    "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect" --connectcode "$code" 2>/dev/null || true
    step_ok "Jump Desktop configured"
  else
    echo "${RED}Jump Desktop Connect not installed. Run Option 1 first.${RESET}"
  fi
}

launch_monitor() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "${RED}tmux not installed. Run Option 1 first.${RESET}"
    read -p "Press Enter..."; return
  fi
  if ! command -v htop >/dev/null 2>&1; then
    echo "${RED}htop not installed. Run Option 1 first.${RESET}"
    read -p "Press Enter..."; return
  fi
  tmux kill-session -t monitor 2>/dev/null || true
  if command -v macmon >/dev/null 2>&1; then
    tmux new-session -s monitor "htop" \; split-window -h "macmon" \; select-pane -t 0
  else
    echo "${YELLOW}macmon not found — launching htop only.${RESET}"
    tmux new-session -s monitor "htop"
  fi
}

send_extreme_alert() {
  local msg="$1"
  [[ -f "$ALERT_LOCK" ]] && [[ $(($(date +%s) - $(cat "$ALERT_LOCK"))) -lt 3600 ]] && return
  local ALERTID
  ALERTID=$(cat "$HOME/.server-alerts/id" 2>/dev/null || echo "")
  [[ -z "$ALERTID" ]] && return
  osascript - "$msg" "$ALERTID" <<'EOF' 2>/dev/null || true
on run argv
  tell application "Messages"
    send (item 1 of argv) to buddy (item 2 of argv)
  end tell
end run
EOF
  date +%s > "$ALERT_LOCK"
}

# ── CLI flag handler (for cron health checks) ──
if [[ "${1:-}" == "--alert" ]]; then
  send_extreme_alert "${2:-Server alert}"
  exit 0
fi

# ── Start ──
show_main_menu
