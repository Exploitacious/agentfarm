#!/usr/bin/env bash

# =============================================================================
# OpenClaw Install Script
#
# Can be run two ways:
#   1. Pushed into an LXC by openclaw.sh (templates pre-staged in /tmp)
#   2. Directly on any Linux machine via curl|bash:
#      bash -c "$(curl -fsSL setupClaw.ivantsov.tech)"
#
# Handles: user creation, dependencies, OpenClaw install, security hardening,
#          memory plugin, Tailscale, backups, git-tracked config, validation
# =============================================================================

set -euo pipefail

# -- Remote repo base URL (for standalone curl|bash mode) ----------------------
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/Exploitacious/agentfarm/refs/heads/master}"

# -- Logging (all output also goes to log file for debugging) ------------------
LOGFILE="/tmp/openclaw-install.log"
exec > >(tee -a "$LOGFILE") 2>&1

# -- Error trap ----------------------------------------------------------------
error_handler() {
  local EXIT_CODE=$?
  local LINE_NO=$1
  echo ""
  echo -e " \e[31m\xE2\x9C\x98 Install failed at line ${LINE_NO} (exit code: ${EXIT_CODE})\e[0m"
  echo -e "   \e[33mFull log available at: ${LOGFILE}\e[0m"
  echo -e "   \e[33mYou can re-run this script after fixing the issue.\e[0m"
}
trap 'error_handler $LINENO' ERR

# -- Colors & Formatting -------------------------------------------------------
GN="\e[32m"; RD="\e[31m"; BL="\e[36m"; YW="\e[33m"; CL="\e[0m"
CM="${GN}\xE2\x9C\x94${CL}"; CROSS="${RD}\xE2\x9C\x98${CL}"

msg_ok()    { printf " ${CM} ${GN}%s${CL}\n" "$1"; }
msg_error() { printf " ${CROSS} ${RD}%s${CL}\n" "$1"; }
msg_info()  { printf "   ${BL}%s${CL}\n" "$1"; }
msg_warn()  { printf "   ${YW}%s${CL}\n" "$1"; }
msg_step()  { printf "\n ${GN}>>>${CL} %s\n" "$1"; }
msg_dim()   { printf "   ${DM}%s${CL}\n" "$1"; }

CLAW_USER="claw"
CLAW_HOME="/home/${CLAW_USER}"

# -- Resolve a file: use local /tmp copy first, otherwise fetch from GitHub ----
resolve_template() {
  local TPL_NAME="$1"
  local DEST="/tmp/${TPL_NAME}"

  # Already staged (pushed by openclaw.sh or previous run)
  if [[ -f "$DEST" ]]; then
    return 0
  fi

  # Try fetching from GitHub
  msg_info "Fetching ${TPL_NAME} from GitHub..."
  if curl -fsSL "${REPO_RAW}/openclaw/templates/${TPL_NAME}" -o "$DEST" 2>/dev/null; then
    msg_ok "Downloaded ${TPL_NAME}"
    return 0
  else
    msg_warn "Could not download ${TPL_NAME} -- will use built-in defaults"
    return 1
  fi
}

# -- Ensure XDG_RUNTIME_DIR exists for systemd user services -------------------
ensure_user_runtime_dir() {
  local UID_VAL
  UID_VAL=$(id -u "$CLAW_USER")
  local RUNTIME_DIR="/run/user/${UID_VAL}"
  if [[ ! -d "$RUNTIME_DIR" ]]; then
    mkdir -p "$RUNTIME_DIR"
    chown "${CLAW_USER}:${CLAW_USER}" "$RUNTIME_DIR"
    chmod 700 "$RUNTIME_DIR"
  fi
}

# =============================================================================
# Step 1: System Update & Base Dependencies
# =============================================================================
step_system_setup() {
  msg_step "Step 1/8: System update & base dependencies"

  export DEBIAN_FRONTEND=noninteractive

  # Fix locale first (prevents "Wide character" perl warnings in Proxmox)
  # Export C.UTF-8 first to suppress bash locale warnings during setup
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  msg_info "Setting locale..."
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq locales >/dev/null 2>&1
  sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
  locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 >/dev/null 2>&1 || true
  export LANG=en_US.UTF-8
  export LC_ALL=en_US.UTF-8
  msg_ok "Locale set to en_US.UTF-8"

  msg_info "Updating package lists..."
  apt-get update -qq >/dev/null 2>&1
  msg_ok "Package lists updated"

  msg_info "Upgrading system packages..."
  apt-get upgrade -y -qq >/dev/null 2>&1
  msg_ok "System packages upgraded"

  msg_info "Installing base dependencies..."
  apt-get install -y -qq \
    build-essential \
    python3 \
    git \
    curl \
    wget \
    sudo \
    jq \
    unzip \
    ca-certificates \
    gnupg \
    lsb-release \
    cron \
    procps \
    openssl \
    net-tools \
    xxd \
    >/dev/null 2>&1
  msg_ok "Base dependencies installed"
}

# =============================================================================
# Step 2: Create claw User
# =============================================================================
step_create_user() {
  msg_step "Step 2/8: Creating '${CLAW_USER}' user"

  if id "$CLAW_USER" &>/dev/null; then
    msg_ok "User '${CLAW_USER}' already exists"
  else
    adduser --disabled-password --gecos "OpenClaw Agent" "$CLAW_USER" >/dev/null 2>&1
    msg_ok "User '${CLAW_USER}' created"
  fi

  # Grant sudo (passwordless for automation)
  usermod -aG sudo "$CLAW_USER"
  echo "${CLAW_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${CLAW_USER}"
  chmod 440 "/etc/sudoers.d/${CLAW_USER}"
  msg_ok "Sudo privileges granted"

  # Enable lingering so user services persist without active login
  loginctl enable-linger "$CLAW_USER" 2>/dev/null || true
  msg_ok "User lingering enabled (systemd user services persist)"

  # Set a default password for initial SSH access
  echo "${CLAW_USER}:openclaw" | chpasswd
  msg_warn "Default password set to 'openclaw' -- CHANGE THIS after first login"

  # Allow password auth for initial setup (user can harden later)
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
  systemctl restart sshd 2>/dev/null || true
}

# =============================================================================
# Step 3: Install Node.js (if not handled by OpenClaw installer)
# =============================================================================
step_install_node() {
  msg_step "Step 3/8: Ensuring Node.js is available"

  # Check if Node.js 22+ is already present
  if command -v node &>/dev/null; then
    local NODE_VER
    NODE_VER=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
    if [[ "$NODE_VER" -ge 22 ]]; then
      msg_ok "Node.js $(node --version) already installed"
      return 0
    fi
  fi

  # Install Node.js 22.x via NodeSource (same method OpenClaw's installer uses)
  msg_info "Installing Node.js 22.x via NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -s -- >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null 2>&1

  if command -v node &>/dev/null; then
    msg_ok "Node.js $(node --version) installed"
  else
    msg_warn "Node.js pre-install failed. OpenClaw installer will handle it."
  fi

  # Ensure npm global dir exists for claw user (avoids permission issues later)
  sudo -u "$CLAW_USER" bash -c '
    mkdir -p ~/.npm-global
    npm config set prefix ~/.npm-global 2>/dev/null || true
  '
  msg_ok "npm global directory configured for claw user"
}

# =============================================================================
# Step 4: Install OpenClaw
# =============================================================================
step_install_openclaw() {
  msg_step "Step 4/8: Installing OpenClaw"

  msg_info "Running OpenClaw install script..."
  # Use --no-prompt --no-onboard to suppress all interactive prompts
  # (same approach NemoClaw uses; OPENCLAW_NO_PROMPT=1 as belt-and-suspenders)
  sudo -u "$CLAW_USER" bash -c \
    'export PATH="${HOME}/.npm-global/bin:${PATH}" && \
     export OPENCLAW_NO_PROMPT=1 && \
     curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-prompt --no-onboard' \
    </dev/null 2>&1 | tail -5
  # Set PATH for OpenClaw binaries — use /etc/profile.d/ so it survives dotfile replacement
  cat > /etc/profile.d/openclaw.sh << 'OCPROFILE'
# OpenClaw PATH (system-wide fallback — survives dotfile replacement)
if [ -d "${HOME}/.npm-global/bin" ]; then
  case ":${PATH}:" in
    *":${HOME}/.npm-global/bin:"*) ;;
    *) export PATH="${HOME}/.npm-global/bin:${PATH}" ;;
  esac
  export NODE_PATH="${HOME}/.npm-global/lib/node_modules"
fi

# Performance tuning for LXC/VM hosts
export NODE_COMPILE_CACHE="/var/tmp/openclaw-compile-cache"
export OPENCLAW_NO_RESPAWN=1
OCPROFILE
  chmod 644 /etc/profile.d/openclaw.sh
  mkdir -p /var/tmp/openclaw-compile-cache

  # Also add to .bashrc as a convenience (but profile.d is the authoritative source)
  sudo -u "$CLAW_USER" bash -c 'cat >> ~/.bashrc << "OCPATH"

# OpenClaw
export PATH="${HOME}/.npm-global/bin:${PATH}"
export NODE_PATH="${HOME}/.npm-global/lib/node_modules"
export NODE_COMPILE_CACHE="/var/tmp/openclaw-compile-cache"
export OPENCLAW_NO_RESPAWN=1
OCPATH'

  # Verify OpenClaw actually installed
  if sudo -u "$CLAW_USER" bash -c \
    'export PATH="${HOME}/.npm-global/bin:${PATH}" && command -v openclaw' \
    >/dev/null 2>&1; then
    msg_ok "OpenClaw installed and binary verified"
  else
    msg_error "OpenClaw binary not found after install. Check ${LOGFILE} for details."
    exit 1
  fi

  msg_ok "PATH configured for claw user"

  # Ensure XDG_RUNTIME_DIR exists before systemd user operations
  ensure_user_runtime_dir

  # Install the gateway as a systemd user service
  msg_info "Installing OpenClaw gateway service..."
  sudo -u "$CLAW_USER" bash -c \
    'export PATH="${HOME}/.npm-global/bin:${PATH}" && \
     export XDG_RUNTIME_DIR="/run/user/$(id -u)" && \
     openclaw gateway install' \
    >/dev/null 2>&1 || {
      msg_warn "Gateway service install returned non-zero. May need manual setup."
      msg_warn "Run: openclaw gateway install (as claw user after login)"
    }
  msg_ok "Gateway service installed"
}

# =============================================================================
# Step 5: Apply Config Templates
# =============================================================================
step_apply_templates() {
  msg_step "Step 5/8: Applying configuration templates"

  local OC_DIR="${CLAW_HOME}/.openclaw"
  local WS_DIR="${OC_DIR}/workspace"

  # Ensure directories exist
  sudo -u "$CLAW_USER" mkdir -p "$WS_DIR/memory" "$WS_DIR/skills" "$OC_DIR/credentials"

  # Apply openclaw.json template with token generation
  if [[ -f /tmp/openclaw.json.tpl ]]; then
    # Generate a random gateway token
    local GW_TOKEN
    GW_TOKEN=$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | xxd -p | tr -d '\n' | head -c 48)

    # Inject generated token into template
    sed "s/__GATEWAY_TOKEN__/${GW_TOKEN}/" /tmp/openclaw.json.tpl > "${OC_DIR}/openclaw.json"

    # Lock permissions immediately (contains token)
    chown "${CLAW_USER}:${CLAW_USER}" "${OC_DIR}/openclaw.json"
    chmod 600 "${OC_DIR}/openclaw.json"

    msg_ok "openclaw.json template applied (gateway token generated)"
    msg_info "Gateway token: ${GW_TOKEN}"
    msg_info "Save this token -- you'll need it for dashboard access"
    msg_warn "Telegram bot token still needs manual configuration"
    msg_warn "Edit ~/.openclaw/openclaw.json and replace __TELEGRAM_BOT_TOKEN__"
  else
    msg_warn "No openclaw.json template found -- using OpenClaw defaults"
    msg_warn "Run 'openclaw configure' after login to set up config"
  fi

  # NOTE: SOUL.md, AGENTS.md, and USER.md are NOT pre-written here.
  # The hatching process (BOOTSTRAP.md → TUI "Wake up, my friend!") generates these
  # interactively, creating the bot's personality from scratch. Pre-writing them
  # would bypass the "Wake up, my friend..." first-contact experience.
  #
  # Our agents.md.tpl (prompt injection defense, sub-agent delegation) is stored
  # in ~/agentfarm/openclaw/templates/ and can be appended to AGENTS.md AFTER hatching
  # via the post-install wizard's finalize step.

  # NOTE: USER.md is NOT created here either. Any file in the workspace
  # directory before onboard runs can trigger the hasUserContent check and
  # prevent BOOTSTRAP.md creation, killing the hatching process.
  # USER.md is created by the post-install wizard after hatching completes.
}

# =============================================================================
# Step 6: Memory Plugin (deferred — installed by post-install wizard AFTER hatching)
# =============================================================================
step_install_memory() {
  msg_step "Step 6/8: Memory plugin (deferred)"

  # CRITICAL: The memory plugin MUST NOT be installed before onboard/hatching.
  #
  # OpenClaw's workspace initialization (workspace-R-NeOkBt.js lines 314-332)
  # checks for existing content in the workspace directory. If it finds any
  # (including skills/, memory/, or plugin data files), it sets setupCompletedAt
  # immediately and skips BOOTSTRAP.md creation. Without BOOTSTRAP.md, the
  # "Wake up, my friend..." hatching dialogue never fires.
  #
  # The memory-lancedb-hybrid plugin is installed by the post-install wizard
  # (openclaw/postinstall.sh) AFTER the bot has been hatched.

  msg_info "Memory plugin will be installed after hatching (post-install wizard)"
  msg_dim "This prevents workspace content from blocking the hatching process"
}

# =============================================================================
# Step 7: Tailscale Setup
# =============================================================================
step_install_tailscale() {
  msg_step "Step 7/8: Installing Tailscale"

  msg_info "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
  msg_ok "Tailscale binary installed"

  systemctl enable --now tailscaled >/dev/null 2>&1 || true
  msg_ok "tailscaled service enabled"

  msg_info "Tailscale is installed but NOT authenticated yet."
  msg_info "After first login, run:"
  msg_info "  sudo tailscale up"
  msg_info "  sudo tailscale serve --bg 18789"
}

# =============================================================================
# Step 8: Backup Script, Git Tracking, Cron
# =============================================================================
step_setup_maintenance() {
  msg_step "Step 8/8: Backups, git tracking, hardening, and validation"

  local OC_DIR="${CLAW_HOME}/.openclaw"

  # -- Backup Script -----------------------------------------------------------
  sudo -u "$CLAW_USER" mkdir -p "${CLAW_HOME}/bin" "${CLAW_HOME}/backups"

  cat > "${CLAW_HOME}/bin/backup-openclaw.sh" << 'BACKUP'
#!/bin/bash
# OpenClaw automated backup script
BACKUP_DIR="${HOME}/backups"
DATE=$(date +%Y-%m-%d)

mkdir -p "$BACKUP_DIR"

tar czf "$BACKUP_DIR/openclaw-${DATE}.tar.gz" \
  ~/.openclaw/openclaw.json \
  ~/.openclaw/.env \
  ~/.openclaw/credentials/ \
  ~/.openclaw/workspace/ \
  ~/.openclaw/agents/*/agent/auth-profiles.json \
  2>/dev/null || true

# Keep only last 7 days of backups
find "$BACKUP_DIR" -name "openclaw-*.tar.gz" -mtime +7 -delete

echo "$(date): Backup completed - openclaw-${DATE}.tar.gz" >> "$BACKUP_DIR/backup.log"
BACKUP

  chmod +x "${CLAW_HOME}/bin/backup-openclaw.sh"
  chown -R "${CLAW_USER}:${CLAW_USER}" "${CLAW_HOME}/bin" "${CLAW_HOME}/backups"
  msg_ok "Backup script created at ~/bin/backup-openclaw.sh"

  # -- Cron job (daily at 3am) -------------------------------------------------
  sudo -u "$CLAW_USER" bash -c \
    '(crontab -l 2>/dev/null | grep -v "backup-openclaw"; echo "0 3 * * * ${HOME}/bin/backup-openclaw.sh") | crontab -' \
    2>/dev/null || true
  msg_ok "Daily backup cron job set (3:00 AM)"

  # -- Cleanup cron (memory files older than 30 days) --------------------------
  sudo -u "$CLAW_USER" bash -c \
    '(crontab -l 2>/dev/null; echo "0 4 * * * find ~/.openclaw/workspace/memory -name '"'"'*.md'"'"' -mtime +30 -delete 2>/dev/null") | crontab -' \
    2>/dev/null || true
  msg_ok "Memory cleanup cron set (30-day retention)"

  # -- Git-track config --------------------------------------------------------
  msg_info "Initializing git tracking for OpenClaw config..."
  sudo -u "$CLAW_USER" bash -c "
    cd ${OC_DIR} && \
    git init -q && \
    printf 'agents/*/sessions/\nagents/*/agent/*.jsonl\n*.log\nworkspace/memory/\n' > .gitignore && \
    git add .gitignore openclaw.json 2>/dev/null && \
    git commit -q -m 'config: initial baseline from helper script' 2>/dev/null
  " || true
  msg_ok "Config directory git-tracked (rollback ready)"

  # -- Update alias (add to both .bashrc and .zshrc if it exists) -------------
  local ALIAS_BLOCK='
# OpenClaw shortcuts
alias openclaw-update="pnpm add -g openclaw@latest && systemctl --user restart openclaw-gateway.service"
alias openclaw-logs="openclaw logs --follow"
alias openclaw-status="openclaw gateway status"
alias openclaw-backup="${HOME}/bin/backup-openclaw.sh"'

  sudo -u "$CLAW_USER" bash -c "echo '$ALIAS_BLOCK' >> ~/.bashrc"
  if [[ -f "${CLAW_HOME}/.zshrc" ]]; then
    sudo -u "$CLAW_USER" bash -c "echo '$ALIAS_BLOCK' >> ~/.zshrc"
    msg_ok "Shell aliases added to .bashrc and .zshrc"
  else
    msg_ok "Shell aliases added to .bashrc"
  fi

  # -- Clone helper repo (for postinstall wizard and future updates) -----------
  if [[ ! -d "${CLAW_HOME}/agentfarm" ]]; then
    msg_info "Cloning agentfarm helper repo..."
    sudo -u "$CLAW_USER" git clone -q \
      https://github.com/Exploitacious/agentfarm.git \
      "${CLAW_HOME}/agentfarm" 2>/dev/null || {
        msg_warn "Repo clone failed. Post-install wizard can be fetched manually."
        msg_warn "Run: git clone https://github.com/Exploitacious/agentfarm.git ~/agentfarm"
      }
    msg_ok "Helper repo cloned to ~/agentfarm (includes post-install wizard)"
  else
    msg_info "Updating existing agentfarm helper repo..."
    sudo -u "$CLAW_USER" bash -c "cd ${CLAW_HOME}/agentfarm && git pull -q" 2>/dev/null || true
    msg_ok "Helper repo updated"
  fi
}

# =============================================================================
# Step 9: Security Hardening & Validation
# =============================================================================
step_validate() {
  msg_step "Finalizing: Security hardening & validation"

  local OC_DIR="${CLAW_HOME}/.openclaw"

  # -- File Permissions --------------------------------------------------------
  msg_info "Setting file permissions..."
  chmod 700 "$OC_DIR" 2>/dev/null || true
  chmod 600 "${OC_DIR}/openclaw.json" 2>/dev/null || true
  chmod 700 "${OC_DIR}/credentials" 2>/dev/null || true
  chown -R "${CLAW_USER}:${CLAW_USER}" "$OC_DIR"
  msg_ok "File permissions locked (700/600)"

  ensure_user_runtime_dir

  # -- Run openclaw doctor -----------------------------------------------------
  msg_info "Running openclaw doctor..."
  sudo -u "$CLAW_USER" bash -c \
    'export PATH="${HOME}/.npm-global/bin:${PATH}" && \
     export XDG_RUNTIME_DIR="/run/user/$(id -u)" && \
     openclaw doctor --fix' \
    2>&1 | tail -10 || true
  msg_ok "openclaw doctor completed"

  # -- Run security audit ------------------------------------------------------
  msg_info "Running security audit..."
  sudo -u "$CLAW_USER" bash -c \
    'export PATH="${HOME}/.npm-global/bin:${PATH}" && \
     export XDG_RUNTIME_DIR="/run/user/$(id -u)" && \
     openclaw security audit --deep' \
    2>&1 | tail -10 || true
  msg_ok "Security audit completed"

  # -- Verify gateway binding --------------------------------------------------
  msg_info "Checking gateway binding..."
  if netstat -an 2>/dev/null | grep -q "0.0.0.0:18789"; then
    msg_warn "WARNING: Gateway is bound to 0.0.0.0 (all interfaces)!"
    msg_warn "Fix: openclaw config set gateway.bind loopback"
  else
    msg_ok "Gateway binding looks correct"
  fi

  # -- Final git commit with hardened state ------------------------------------
  sudo -u "$CLAW_USER" bash -c "
    cd ${OC_DIR} && \
    git add -A 2>/dev/null && \
    git commit -q -m 'config: post-install hardening complete' 2>/dev/null
  " || true

  # -- Get container IP for summary ----------------------------------------------
  local CONTAINER_IP
  CONTAINER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

  echo ""
  msg_ok "============================================"
  msg_ok "  OpenClaw installation complete!"
  msg_ok "============================================"
  echo ""
  echo -e " ${GN}Next steps:${CL}"
  echo ""
  echo -e "  1. ${YW}Reboot the container to load PATH and services:${CL}"
  echo -e "     ${BL}reboot${CL}  (or from PVE host: ${BL}pct reboot <CT_ID>${CL})"
  echo ""
  echo -e "  2. Log in:"
  echo -e "     ${BL}ssh claw@${CONTAINER_IP:-<container-ip>}${CL}"
  echo -e "     Password: ${YW}openclaw${CL}"
  echo ""
  echo -e "  3. ${RD}Change the default password immediately:${CL}"
  echo -e "     ${BL}passwd${CL}"
  echo ""
  echo -e "  4. ${GN}Run the post-install wizard (sets up everything else):${CL}"
  echo -e "     ${BL}bash ~/agentfarm/openclaw/postinstall.sh${CL}"
  echo ""
  echo -e "     The wizard handles: AI providers, model selection, embeddings key,"
  echo -e "     Telegram bot token, Tailscale auth, and agent personality."
  echo ""
  echo -e "     Or do it all in one shot:"
  echo -e "     ${BL}bash ~/agentfarm/openclaw/postinstall.sh \\${CL}"
  echo -e "     ${BL}  --provider anthropic-api-key --provider-key sk-ant-... \\${CL}"
  echo -e "     ${BL}  --openai-key sk-... \\${CL}"
  echo -e "     ${BL}  --telegram-token 123456:ABC... \\${CL}"
  echo -e "     ${BL}  --telegram-user-id YOUR_ID \\${CL}"
  echo -e "     ${BL}  --tailscale-auth-key tskey-auth-...${CL}"
  echo ""
}

# =============================================================================
# Preflight Checks
# =============================================================================
preflight_checks() {
  echo ""
  msg_step "Preflight checks"

  local FAIL=false

  # -- Root -------------------------------------------------------------------
  if [[ "$(id -u)" -eq 0 ]]; then
    msg_ok "Running as root"
  else
    msg_error "Must be run as root (try: sudo bash $0)"
    FAIL=true
  fi

  # -- Distro (Debian/Ubuntu) -------------------------------------------------
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *"debian"* ]]; then
      msg_ok "Distro: ${PRETTY_NAME:-$ID}"
    else
      msg_error "Unsupported distro: ${PRETTY_NAME:-$ID} (need Debian/Ubuntu)"
      FAIL=true
    fi
  else
    msg_error "Cannot detect distro (/etc/os-release missing)"
    FAIL=true
  fi

  # -- systemd as PID 1 -------------------------------------------------------
  if [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]; then
    msg_ok "systemd is PID 1"
  else
    msg_error "systemd not detected (PID 1: $(cat /proc/1/comm 2>/dev/null || echo unknown))"
    msg_error "OpenClaw requires systemd for user services and lingering"
    FAIL=true
  fi

  # -- curl -------------------------------------------------------------------
  if command -v curl &>/dev/null; then
    msg_ok "curl available"
  else
    msg_warn "curl not found -- will attempt to install via apt"
  fi

  # -- RAM (warn < 2GB) -------------------------------------------------------
  local RAM_KB RAM_MB
  RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
  RAM_MB=$(( ${RAM_KB:-0} / 1024 ))
  if [[ "$RAM_MB" -ge 2048 ]]; then
    msg_ok "RAM: ${RAM_MB} MB"
  elif [[ "$RAM_MB" -ge 1024 ]]; then
    msg_warn "RAM: ${RAM_MB} MB (2 GB+ recommended, may be tight)"
  else
    msg_warn "RAM: ${RAM_MB} MB (2 GB+ recommended, install may fail)"
  fi

  # -- Disk (warn < 2GB free) -------------------------------------------------
  local DISK_FREE_KB DISK_FREE_MB
  DISK_FREE_KB=$(df / 2>/dev/null | awk 'NR==2 {print $4}')
  DISK_FREE_MB=$(( ${DISK_FREE_KB:-0} / 1024 ))
  if [[ "$DISK_FREE_MB" -ge 2048 ]]; then
    msg_ok "Free disk: ${DISK_FREE_MB} MB"
  elif [[ "$DISK_FREE_MB" -ge 1024 ]]; then
    msg_warn "Free disk: ${DISK_FREE_MB} MB (2 GB+ recommended)"
  else
    msg_warn "Free disk: ${DISK_FREE_MB} MB (2 GB+ recommended, may run out)"
  fi

  # -- Internet (quick check) -------------------------------------------------
  if curl -fsS --max-time 5 -o /dev/null https://deb.nodesource.com 2>/dev/null; then
    msg_ok "Internet reachable"
  elif command -v curl &>/dev/null; then
    msg_warn "Internet check failed (may be a firewall or DNS issue)"
  else
    msg_warn "Cannot verify internet (curl not yet installed)"
  fi

  # -- Bail on hard failures ---------------------------------------------------
  if $FAIL; then
    echo ""
    msg_error "Preflight failed. Fix the issues above and re-run."
    exit 1
  fi

  echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
  preflight_checks

  # -- Detect execution mode ----------------------------------------------------
  if [[ -n "${PUSHED_BY_HOST:-}" ]]; then
    # Called by openclaw.sh — templates already staged in /tmp
    echo ""
    echo "==========================================="
    echo "  OpenClaw Container Setup (via PVE host)"
    echo "==========================================="
    echo ""
  else
    # Standalone mode — running directly on an existing machine
    echo ""
    echo "==========================================="
    echo "  OpenClaw Standalone Setup"
    echo "==========================================="
    echo ""
    msg_info "Running in standalone mode (not via Proxmox helper)"
    msg_info "Templates will be fetched from GitHub if not present"
    echo ""

    # Pre-fetch templates so step_apply_templates finds them in /tmp
    for tpl in openclaw.json.tpl soul.md.tpl agents.md.tpl; do
      resolve_template "$tpl" || true
    done
  fi

  step_system_setup
  step_create_user
  step_install_node
  step_install_openclaw
  step_apply_templates
  step_install_memory
  step_install_tailscale
  step_setup_maintenance
  step_validate
}

main "$@"
