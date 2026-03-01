#!/bin/bash
# mac4llm.sh — Mac Studio LLM Control Panel v0.40 (March 2026)
# Complete rewrite. Proper dependency management. No silent failures.

# ══════════════════════════════════════════════════════════════
# PHASE 0: BOOTSTRAP — runs before ANYTHING else
# ══════════════════════════════════════════════════════════════

# ── Find and fix PATH for Homebrew ──
fix_brew_path() {
  # Check common brew locations
  if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  elif [[ -f "$HOME/.homebrew/bin/brew" ]]; then
    eval "$("$HOME/.homebrew/bin/brew" shellenv)"
  fi
}
fix_brew_path

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

VERSION="v0.40"

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
STEP_ACTION=""

# ── Detect brew prefix (only if brew exists) ──
detect_brew_prefix() {
  if command -v brew >/dev/null 2>&1; then
    BREW_PREFIX=$(brew --prefix)
  else
    BREW_PREFIX=""
  fi
  if [[ -n "$BREW_PREFIX" ]]; then
    NGINX_CONF_DIR="$BREW_PREFIX/etc/nginx/servers"
    NGINX_CONF="$NGINX_CONF_DIR/lmstudio.conf"
  fi
}
detect_brew_prefix

# ══════════════════════════════════════════════════════════════
# DEPENDENCY SYSTEM — the heart of the rewrite
# ══════════════════════════════════════════════════════════════

# Check if a command exists and report clearly
require_cmd() {
  local cmd="$1"
  local purpose="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "${RED}MISSING: ${BOLD}$cmd${RESET}${RED} — needed for: $purpose${RESET}"
    return 1
  fi
  return 0
}

# Check all dependencies and report what's missing
check_all_dependencies() {
  local missing=0

  echo "${BOLD}${CYAN}Checking dependencies...${RESET}"
  echo ""

  # Always available on macOS
  local ok="${GREEN}✓${RESET}"
  local fail="${RED}✗${RESET}"

  # macOS built-ins (should always exist)
  for cmd in sudo scutil networksetup defaults launchctl pfctl pmset /usr/bin/perl; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "  $ok $cmd"
    else
      echo "  $fail $cmd ${RED}(macOS built-in — something is very wrong)${RESET}"
      missing=$((missing + 1))
    fi
  done

  # Homebrew
  if command -v brew >/dev/null 2>&1; then
    echo "  $ok brew ($(brew --version 2>/dev/null | head -1))"
  else
    echo "  $fail brew ${YELLOW}(will install in setup)${RESET}"
  fi

  # Brew-installed tools
  local BREW_TOOLS="nginx ngrok htop tmux"
  local OPTIONAL_BREW="macmon displayplacer"

  for cmd in $BREW_TOOLS; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "  $ok $cmd"
    else
      echo "  $fail $cmd ${YELLOW}(will install in setup)${RESET}"
    fi
  done

  for cmd in $OPTIONAL_BREW; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "  $ok $cmd"
    else
      echo "  $fail $cmd ${YELLOW}(optional — will try to install)${RESET}"
    fi
  done

  # LM Studio
  if command -v lms >/dev/null 2>&1; then
    echo "  $ok lms (LM Studio CLI)"
  else
    echo "  $fail lms ${YELLOW}(will install in setup)${RESET}"
  fi

  echo ""
  return $missing
}

# Install Homebrew if missing, fix PATH permanently
install_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  echo "${YELLOW}Installing Homebrew (this may take several minutes)...${RESET}"
  echo "${YELLOW}You may be prompted for your password once.${RESET}"
  echo ""

  # The brew installer is interactive — it REQUIRES pressing Enter
  # and outputs tons of noise. We use NONINTERACTIVE=1 to skip the
  # Enter prompt, and pipe output through a simple progress indicator.
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>&1 | \
    while IFS= read -r line; do
      # Only show meaningful progress lines
      if echo "$line" | grep -qiE "^==> (Installing|Downloading|Searching)"; then
        echo "  ${CYAN}${line}${RESET}"
      fi
    done

  # Find where it installed and fix PATH
  fix_brew_path

  if ! command -v brew >/dev/null 2>&1; then
    # Try harder
    for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [[ -f "$p" ]]; then
        eval "$("$p" shellenv)"
        break
      fi
    done
  fi

  if command -v brew >/dev/null 2>&1; then
    detect_brew_prefix
    echo "${GREEN}✅ Homebrew installed.${RESET}"
    return 0
  else
    echo "${RED}Homebrew installation failed.${RESET}"
    echo "${YELLOW}Install manually: https://brew.sh then re-run this script.${RESET}"
    return 1
  fi
}

# Install brew packages with clear reporting
install_brew_packages() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "${RED}Cannot install packages — brew not found.${RESET}"
    return 1
  fi

  local REQUIRED_PKGS="nginx ngrok htop tmux"
  local OPTIONAL_PKGS="macmon displayplacer"
  local ok="${GREEN}✓${RESET}"
  local fail="${RED}✗${RESET}"
  local warn="${YELLOW}⚠${RESET}"

  echo "${YELLOW}Installing required packages...${RESET}"
  for pkg in $REQUIRED_PKGS; do
    if command -v "$pkg" >/dev/null 2>&1; then
      echo "  $ok $pkg (already installed)"
    else
      printf "  ${CYAN}Installing $pkg...${RESET}"
      if brew install "$pkg" >/dev/null 2>&1; then
        echo "\r  $ok $pkg installed          "
      else
        echo "\r  $fail $pkg failed            "
      fi
    fi
  done

  echo "${YELLOW}Installing optional packages...${RESET}"
  for pkg in $OPTIONAL_PKGS; do
    if command -v "$pkg" >/dev/null 2>&1; then
      echo "  $ok $pkg (already installed)"
    else
      printf "  ${CYAN}Installing $pkg...${RESET}"
      if brew install "$pkg" >/dev/null 2>&1; then
        echo "\r  $ok $pkg installed          "
      else
        echo "\r  $warn $pkg skipped (optional)"
      fi
    fi
  done

  detect_brew_prefix
}

# ══════════════════════════════════════════════════════════════
# SAFE CONFIG — no source, no code execution
# ══════════════════════════════════════════════════════════════
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
    echo "${RED}lms not found. Install LM Studio first (Setup → Install Software).${RESET}"
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════
# UI HELPERS
# ══════════════════════════════════════════════════════════════
clear_screen() { clear 2>/dev/null || true; }

print_header() {
  clear_screen
  echo "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo "${BLUE}║  ${BOLD}${CYAN}Mac Studio LLM Server Control Panel ${VERSION}${RESET}             ${BLUE}║${RESET}"
  echo "${BLUE}║  ${MAGENTA}Follow steps to fine-tune your Mac to run LM Studio${RESET}       ${BLUE}║${RESET}"
  echo "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

step_ok() {
  echo "${GREEN}✅ $1${RESET}"
  echo "$DIVIDER"
}

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

# ══════════════════════════════════════════════════════════════
# KCPASSWORD — pure perl, no python3, no Xcode needed
# ══════════════════════════════════════════════════════════════
generate_kcpassword() {
  local password="$1"
  if [[ -z "$password" ]]; then
    echo "${RED}Empty password.${RESET}"
    return 1
  fi

  echo "$password" | /usr/bin/perl -e '
    my $pass = <STDIN>;
    chomp $pass;
    if (length($pass) == 0) { die "empty password"; }
    my @key = (0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F);
    my $pad = 12 - (length($pass) % 12);
    $pass .= "\0" x $pad;
    my $encoded = "";
    for my $i (0..length($pass)-1) {
      $encoded .= chr(ord(substr($pass,$i,1)) ^ $key[$i % scalar(@key)]);
    }
    open(my $fh, ">:raw", "/tmp/kcpassword") or die "Cannot write: $!";
    print $fh $encoded;
    close($fh);
  '

  if [[ ! -f /tmp/kcpassword ]]; then
    echo "${RED}kcpassword generation failed.${RESET}"
    return 1
  fi

  sudo cp /tmp/kcpassword /etc/kcpassword
  sudo chmod 600 /etc/kcpassword
  sudo chown root:wheel /etc/kcpassword
  rm -f /tmp/kcpassword

  # Verify it was written
  if sudo test -f /etc/kcpassword; then
    echo "${GREEN}  kcpassword written to /etc/kcpassword${RESET}"
    return 0
  else
    echo "${RED}  Failed to copy kcpassword to /etc/${RESET}"
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════
# MINIMAL GUI
# ══════════════════════════════════════════════════════════════
configure_minimal_gui() {
  echo "${BOLD}${YELLOW}Step: Configure minimal GUI${RESET}"

  sudo mkdir -p /usr/local/bin
  mkdir -p "$HOME/Library/LaunchAgents"

  # Only write display script if displayplacer is available
  if command -v displayplacer >/dev/null 2>&1; then
    sudo tee /usr/local/bin/minimal-display.sh > /dev/null <<'MINDISP'
#!/bin/bash
sleep 10
DISP_ID=$(displayplacer list 2>/dev/null | grep "Persistent screen id" | head -1 | awk '{print $NF}')
if [[ -n "$DISP_ID" ]]; then
  displayplacer "id:${DISP_ID} res:800x600 hz:30 color_depth:4 scaling:off" 2>/dev/null || true
fi
MINDISP
    sudo chmod +x /usr/local/bin/minimal-display.sh

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
  else
    echo "${YELLOW}  displayplacer not found — skipping virtual display config.${RESET}"
  fi

  # These defaults commands always work (macOS built-in)
  local ERRORS=0

  defaults write com.apple.finder DisableAllAnimations -bool true || ((ERRORS++))
  defaults write com.apple.finder CreateDesktop -bool false || ((ERRORS++))
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
  sudo defaults write com.apple.universalaccess reduceTransparency -bool true 2>/dev/null

  launchctl unload -w /System/Library/LaunchAgents/com.apple.notificationcenterui.plist 2>/dev/null || true
  defaults write com.apple.assistant.support "Assistant Enabled" -bool false
  launchctl disable "gui/$(id -u)/com.apple.Siri" 2>/dev/null || true
  defaults write com.apple.Spotlight MenuItemHidden -bool true
  defaults -currentHost write com.apple.screensaver idleTime -int 0
  defaults write com.apple.dashboard mcx-disabled -bool true 2>/dev/null || true
  defaults write -g CGFontRenderingFontSmoothingDisabled -bool true
  defaults write com.apple.loginwindow TALLogoutSavesState -bool false
  defaults write NSGlobalDomain NSQuitAlwaysKeepsWindows -bool false

  killall Finder 2>/dev/null || true
  killall Dock 2>/dev/null || true
  killall SystemUIServer 2>/dev/null || true

  if [[ $ERRORS -eq 0 ]]; then
    step_ok "Minimal GUI configured"
  else
    echo "${YELLOW}⚠ Minimal GUI configured with $ERRORS warnings (non-critical).${RESET}"
    echo "$DIVIDER"
  fi
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
    if sudo networksetup -setmanual "$SERVICE" "$IP" "$SUBNET" "$ROUTER"; then
      sudo networksetup -setdnsservers "$SERVICE" 8.8.8.8
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
        sudo networksetup -setairportpower "$WIFI_DEV" off 2>/dev/null
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
    echo "${YELLOW}  Applying hardening (this takes a moment)...${RESET}"
    {
      # Disable unused services
      for svc in smbd AppleFileServer ftp netbiosd screensharing printd Siri mDNSResponder; do
        sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple."$svc".plist 2>/dev/null || true
      done
      sudo launchctl disable system/com.apple.screensharing 2>/dev/null || true
      defaults write com.apple.NetworkBrowser DisableAirDrop -bool YES
      sudo defaults write /Library/Preferences/com.apple.Bluetooth ControllerPowerState -int 0
      sudo launchctl stop com.apple.blued 2>/dev/null || true

      # Power management
      sudo pmset -a sleep 0 displaysleep 0 disksleep 0 autopoweroff 0
      sudo pmset -a autorestart 1

      # SSH + remote events
      sudo systemsetup -setremotelogin on
      sudo systemsetup -setremoteappleevents off

      # Spotlight
      sudo mdutil -i off -a
      sudo mdutil -E -a

      # Screen lock
      sudo defaults write /Library/Preferences/com.apple.loginwindow DisableScreenLock -bool true
      defaults write com.apple.screensaver askForPassword -int 0
      defaults write com.apple.screensaver askForPasswordDelay -int 0
      defaults -currentHost write com.apple.screensaver idleTime -int 0
      sudo sysadminctl -screenLock off 2>/dev/null || true
    } >/dev/null 2>&1

    step_ok "System hardened (services disabled, never-sleep, SSH on, screen lock off)"
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
        step_ok "FileVault disabled"

        # Check if decryption is still in progress
        local DEC_STATUS
        DEC_STATUS=$(sudo fdesetup status 2>/dev/null)
        if echo "$DEC_STATUS" | grep -qi "progress\|percent"; then
          echo "${YELLOW}⏳ Disk decryption in progress. Auto-login won't work until complete.${RESET}"
          echo ""
          echo "  ${CYAN}1${RESET}) Wait here and monitor until done"
          echo "  ${CYAN}2${RESET}) Continue setup (decryption runs in background)"
          read -p "${YELLOW}Choose [2]: ${RESET}" DECWAIT
          if [[ "$DECWAIT" == "1" ]]; then
            echo "${YELLOW}Monitoring decryption (updates every 30s, Ctrl+C to stop)...${RESET}"
            echo "$DIVIDER"
            while true; do
              DEC_STATUS=$(sudo fdesetup status 2>/dev/null)
              local TIMESTAMP
              TIMESTAMP=$(date '+%H:%M:%S')
              if echo "$DEC_STATUS" | grep -q "FileVault is Off"; then
                echo "${GREEN}${TIMESTAMP} — ✅ Decryption complete!${RESET}"
                echo "$DIVIDER"
                break
              fi
              local PCT
              PCT=$(echo "$DEC_STATUS" | grep -o '[0-9]*' | tail -1)
              echo "${CYAN}${TIMESTAMP}${RESET} — Decrypting... ${BOLD}${PCT}%${RESET}"
              sleep 30
            done
          else
            echo "${YELLOW}Decryption continues in background.${RESET}"
            echo "${CYAN}  Check with: sudo fdesetup status${RESET}"
            echo "$DIVIDER"
          fi
        fi
      else
        step_fail "FileVault disable failed — wrong password?"
        if [[ $STEP_ACTION == "menu" ]]; then
          rm -f "$FV_PLIST"; unset FV_PASS; trap - EXIT; return
        fi
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

      # Method 1: sysadminctl
      echo "${YELLOW}  Applying method 1 (sysadminctl)...${RESET}"
      sudo sysadminctl -autologin set -userName "$USER" -password "$AL_PASS" 2>/dev/null
      echo "${GREEN}  Method 1 applied.${RESET}"

      # Method 2: loginwindow preference
      echo "${YELLOW}  Applying method 2 (loginwindow pref)...${RESET}"
      sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$USER"
      echo "${GREEN}  Method 2 applied.${RESET}"

      # Method 3: kcpassword via perl (no python3/Xcode needed)
      echo "${YELLOW}  Applying method 3 (kcpassword via perl)...${RESET}"
      generate_kcpassword "$AL_PASS"
      local KC_RC=$?

      # Screen lock disable
      echo "${YELLOW}  Disabling screen lock...${RESET}"
      sudo defaults write /Library/Preferences/com.apple.loginwindow DisableScreenLock -bool true
      defaults write com.apple.screensaver askForPassword -int 0
      defaults write com.apple.screensaver askForPasswordDelay -int 0
      defaults -currentHost write com.apple.screensaver idleTime -int 0
      sudo sysadminctl -screenLock off 2>/dev/null || true

      unset AL_PASS

      if [[ $KC_RC -eq 0 ]]; then
        step_ok "Auto-login configured for $USER (3 methods + screen lock disabled)"
      else
        echo "${YELLOW}⚠ Auto-login partially configured (kcpassword failed).${RESET}"
        echo "${YELLOW}  Methods 1 & 2 applied. May still work. Reboot to test.${RESET}"
        echo "$DIVIDER"
      fi
    else
      echo "${RED}Empty password — skipping auto-login.${RESET}"; echo "$DIVIDER"
    fi
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

    # Homebrew
    install_homebrew
    if ! command -v brew >/dev/null 2>&1; then
      step_fail "Homebrew installation failed — cannot install other tools"
      [[ $STEP_ACTION == "menu" ]] && return
    else
      # Brew packages
      install_brew_packages

      # LM Studio
      echo "${YELLOW}Installing LM Studio CLI...${RESET}"
      if command -v lms >/dev/null 2>&1; then
        echo "  ${GREEN}✓${RESET} lms already installed"
      else
        curl -fsSL https://lmstudio.ai/install.sh | bash
        if command -v lms >/dev/null 2>&1; then
          echo "  ${GREEN}✓${RESET} lms installed"
        else
          echo "  ${RED}✗${RESET} lms installation may have failed"
          echo "  ${YELLOW}Visit https://lmstudio.ai to install manually${RESET}"
        fi
      fi

      # Jump Desktop
      echo "${YELLOW}Installing Jump Desktop Connect...${RESET}"
      if [[ -f "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect" ]]; then
        echo "  ${GREEN}✓${RESET} Jump Desktop Connect already installed"
      else
        if curl -L -o /tmp/JumpDesktopConnect.pkg https://jumpdesktop.com/downloads/connect/mac 2>/dev/null; then
          sudo installer -pkg /tmp/JumpDesktopConnect.pkg -target /
          rm -f /tmp/JumpDesktopConnect.pkg
          if [[ -f "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect" ]]; then
            echo "  ${GREEN}✓${RESET} Jump Desktop Connect installed"
          else
            echo "  ${YELLOW}⚠${RESET} Jump Desktop may need manual install"
          fi
        else
          echo "  ${YELLOW}⚠${RESET} Could not download Jump Desktop"
        fi
      fi

      step_ok "Software installation complete"
    fi
  else
    echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"
  fi

  # ── STEP: Firewall ──
  echo "${BOLD}${YELLOW}Step: Configure firewall (SSH-only inbound)${RESET}"
  echo "  ${CYAN}1${RESET}) Apply firewall rules"
  echo "  ${CYAN}2${RESET}) Skip"
  read -p "${YELLOW}Choose [1]: ${RESET}" FWCHOICE
  if [[ "${FWCHOICE:-1}" == "1" ]]; then
    echo "${YELLOW}  Enabling application firewall...${RESET}"
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on 2>/dev/null
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on 2>/dev/null
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned off 2>/dev/null

    echo "${YELLOW}  Configuring pf firewall...${RESET}"
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

    if sudo pfctl -ef /etc/pf.conf 2>/dev/null; then
      step_ok "Firewall active — only SSH (port 22) open inbound"
    else
      echo "${YELLOW}⚠ pf firewall may already be running. Rules applied.${RESET}"
      echo "$DIVIDER"
    fi
  else
    echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"
  fi

  # ── Health monitoring cron ──
  local SCRIPT_PATH
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  local CRON_LINE="*/5 * * * * curl -sf http://127.0.0.1:80/health || $SCRIPT_PATH --alert 'LLM server unreachable'"
  if ! crontab -l 2>/dev/null | grep -qF "LLM server unreachable"; then
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab - 2>/dev/null
  fi

  # ── STEP: Start services ──
  echo "${BOLD}${YELLOW}Step: Start LM Studio server + Nginx${RESET}"
  if ! command -v lms >/dev/null 2>&1; then
    echo "${YELLOW}  LM Studio not installed — skipping service start.${RESET}"
    echo "$DIVIDER"
  elif ! command -v nginx >/dev/null 2>&1; then
    echo "${YELLOW}  Nginx not installed — skipping service start.${RESET}"
    echo "$DIVIDER"
  else
    echo "  ${CYAN}1${RESET}) Start now"
    echo "  ${CYAN}2${RESET}) Skip (start manually later)"
    read -p "${YELLOW}Choose [1]: ${RESET}" STARTCHOICE
    if [[ "${STARTCHOICE:-1}" == "1" ]]; then
      load_config
      if [[ -z "$TOKEN" ]]; then
        TOKEN=$(openssl rand -hex 32); save_config
        echo "${GREEN}  Auto-generated token: ${TOKEN:0:8}...${RESET}"
      fi
      create_launchd_plist
      rebuild_nginx_config
    else
      echo "${YELLOW}Skipped.${RESET}"; echo "$DIVIDER"
    fi
  fi

  # ── DONE — reboot prompt at the very end ──
  echo ""
  echo "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${RESET}"
  echo "${BOLD}${GREEN}  ✅ Setup complete!${RESET}"
  echo "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${RESET}"
  echo ""
  echo "  ${CYAN}1${RESET}) Reboot now (recommended if you changed FileVault/auto-login)"
  echo "  ${CYAN}2${RESET}) Return to main menu"
  read -p "${YELLOW}Choose [2]: ${RESET}" FINAL_REB
  if [[ "$FINAL_REB" == "1" ]]; then
    echo "${YELLOW}Rebooting in 3 seconds...${RESET}"
    sleep 3
    sudo reboot
  fi
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
  echo "${GREEN}  LM Studio server registered (port ${PORT}, host 127.0.0.1).${RESET}"
}

rebuild_nginx_config() {
  load_config
  if [[ -z "$TOKEN" ]]; then
    echo "${RED}Bearer token is empty. Set it first (Main Menu → 2 → 5).${RESET}"
    return 1
  fi

  if ! command -v nginx >/dev/null 2>&1; then
    echo "${RED}nginx not found. Install it first (Main Menu → 1 → Install Software).${RESET}"
    return 1
  fi

  detect_brew_prefix
  if [[ -z "$BREW_PREFIX" ]]; then
    echo "${RED}Cannot determine Homebrew prefix. Is brew installed?${RESET}"
    return 1
  fi

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

  echo "${YELLOW}  Testing nginx config...${RESET}"
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
    echo "  ${CYAN}4${RESET}) Check dependencies"
    echo "  ${CYAN}5${RESET}) Exit"
    echo ""
    read -p "${YELLOW}Choose (1-5): ${RESET}" choice
    case $choice in
      1) first_time_setup ;;
      2) lmstudio_config_menu ;;
      3) launch_monitor ;;
      4) check_all_dependencies; read -p "${CYAN}Press Enter...${RESET}" ;;
      5) echo "${GREEN}👋 Goodbye!${RESET}"; return 0 ;;
    esac
  done
}

lmstudio_config_menu() {
  while true; do
    load_config
    if ! command -v lms >/dev/null 2>&1; then
      print_header
      echo "${RED}LM Studio not found.${RESET}"
      echo "${YELLOW}Run Option 1 (Setup) → Install Software step first.${RESET}"
      read -p "Press Enter..."; return
    fi
    print_header
    echo "${BOLD}${GREEN}LM Studio Status${RESET}"
    echo "  ${CYAN}Port:${RESET}   $PORT"
    if [[ -n "$TOKEN" ]]; then
      echo "  ${CYAN}Token:${RESET}  ${TOKEN:0:8}... (masked)"
    else
      echo "  ${CYAN}Token:${RESET}  ${RED}NOT SET${RESET}"
    fi
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
         if [[ -n "$m" ]]; then
           echo "${YELLOW}Downloading model...${RESET}"
           lms get "$m"
         fi ;;
      2) echo "${YELLOW}Unloading all models...${RESET}"
         lms unload --all
         step_ok "All models unloaded" ;;
      3) read -p "Model ID: " id
         read -p "GPU layers [max]: " g; g=${g:-max}
         read -p "Context length [32768]: " c; c=${c:-32768}
         echo "${YELLOW}Loading model...${RESET}"
         lms load "$id" --gpu="$g" --context-length="$c" ;;
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
    PORT=$p; save_config
    create_launchd_plist
    rebuild_nginx_config
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
  if ! command -v ngrok >/dev/null 2>&1; then
    echo "${RED}ngrok not installed. Run Setup → Install Software first.${RESET}"; return
  fi
  pkill ngrok 2>/dev/null || true
  read -p "ngrok authtoken: " tok
  if [[ -z "$tok" ]]; then
    echo "${RED}No token entered.${RESET}"; return
  fi
  ngrok config add-authtoken "$tok"
  nohup ngrok http 80 > ~/ngrok.log 2>&1 &
  sleep 3
  local URL
  URL=$(curl -sf http://127.0.0.1:4040/api/tunnels 2>/dev/null \
    | grep -o '"public_url":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [[ -n "$URL" ]]; then
    step_ok "ngrok tunnel active: $URL"
  else
    echo "${GREEN}✅ ngrok started. Check ~/ngrok.log or http://127.0.0.1:4040${RESET}"
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
  if [[ -f "$LAUNCHD_PLIST" ]]; then
    launchctl bootout "gui/$(id -u)/com.llmstudio.server" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null || true
    step_ok "MCP config saved, LM Studio restarted"
  else
    step_ok "MCP config saved"
  fi
}

jump_setup() {
  if [[ ! -f "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect" ]]; then
    echo "${RED}Jump Desktop Connect not installed. Run Setup → Install Software first.${RESET}"
    return
  fi
  echo "${YELLOW}On another device, go to: https://app.jumpdesktop.com${RESET}"
  echo "${YELLOW}Get a Connect Code, then enter it below.${RESET}"
  read -p "Connect Code: " code
  if [[ -z "$code" ]]; then
    echo "${RED}No code entered.${RESET}"; return
  fi
  "/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect" --connectcode "$code"
  step_ok "Jump Desktop configured"
}

launch_monitor() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "${RED}tmux not installed. Run Setup → Install Software first.${RESET}"
    read -p "Press Enter..."; return
  fi
  if ! command -v htop >/dev/null 2>&1; then
    echo "${RED}htop not installed. Run Setup → Install Software first.${RESET}"
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

# ── Auto-bootstrap: ensure brew + PATH before anything ──
auto_bootstrap() {
  # Fix PATH first
  fix_brew_path

  # If brew still not found, install it
  if ! command -v brew >/dev/null 2>&1; then
    echo ""
    echo "${YELLOW}Homebrew is not installed. It's required for this tool.${RESET}"
    echo "${YELLOW}Installing Homebrew now...${RESET}"
    echo ""
    install_homebrew
    if ! command -v brew >/dev/null 2>&1; then
      echo ""
      echo "${RED}FATAL: Could not install Homebrew.${RESET}"
      echo "${RED}Please install manually: https://brew.sh${RESET}"
      echo "${RED}Then re-run this script.${RESET}"
      exit 1
    fi
  fi

  # Ensure PATH is in .zshrc for future sessions
  local SHELL_RC="$HOME/.zshrc"
  if ! grep -qF "brew shellenv" "$SHELL_RC" 2>/dev/null; then
    local BREW_BIN
    BREW_BIN=$(which brew)
    echo "" >> "$SHELL_RC"
    echo "# Homebrew PATH (added by mac4llm.sh)" >> "$SHELL_RC"
    echo "eval \"\$(${BREW_BIN} shellenv)\"" >> "$SHELL_RC"
  fi

  # Ensure script auto-launches on SSH login
  local SCRIPT_PATH
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  if ! grep -qF "mac4llm" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# Auto-launch LLM control panel" >> "$SHELL_RC"
    echo "[[ -t 1 ]] && $SCRIPT_PATH" >> "$SHELL_RC"
  fi

  detect_brew_prefix
}

auto_bootstrap

# ── Start ──
show_main_menu
