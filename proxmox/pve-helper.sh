#!/usr/bin/env bash

# =============================================================================
# agentfarm Proxmox Helper
# Unified menu: pick a bot (OpenClaw / Hermes / Standard LXC), pick an Ubuntu
# release, and provision an LXC container ready for that bot.
#
# Run this on your Proxmox host (not inside a container).
#
# Usage:
#   Local:  bash proxmox/pve-helper.sh
#   Remote: bash -c "$(curl -fsSL pveAI.ivantsov.tech)"
# =============================================================================

set -euo pipefail

# -- Remote repo base URL (for curl|bash mode) --------------------------------
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/Exploitacious/agentfarm/refs/heads/master}"

# -- Error trap (cleanup on failure) -------------------------------------------
cleanup_on_error() {
  local EXIT_CODE=$?
  if [[ $EXIT_CODE -ne 0 ]]; then
    echo ""
    echo -e " \e[31m\xE2\x9C\x98 Script failed (exit code: ${EXIT_CODE})\e[0m"
    if [[ -n "${CT_ID:-}" ]]; then
      echo -e "   \e[33mContainer ${CT_ID} may have been partially created.\e[0m"
      echo -e "   \e[33mTo clean up: pct stop ${CT_ID} && pct destroy ${CT_ID}\e[0m"
    fi
  fi
}
trap cleanup_on_error EXIT

# -- Colors & Formatting ------------------------------------------------------
BL="\e[36m"
GN="\e[32m"
RD="\e[31m"
YW="\e[33m"
CL="\e[0m"
HOLD=" "
CM="${GN}\xE2\x9C\x94${CL}"
CROSS="${RD}\xE2\x9C\x98${CL}"

msg_ok()    { printf " ${CM} ${GN}%s${CL}\n" "$1"; }
msg_error() { printf " ${CROSS} ${RD}%s${CL}\n" "$1"; }
msg_info()  { printf " ${HOLD} ${BL}%s${CL}\n" "$1"; }
msg_warn()  { printf " ${HOLD} ${YW}%s${CL}\n" "$1"; }

header_info() {
  clear
  cat <<"EOF"

                          _    __
   ____ _____ ____  ____  / |__/ _____ __________ ___
  / __ `/ __ `/ _ \/ __ \/ __/ / __/ _` / __/ __ `__ \
 / /_/ / /_/ /  __/ / / / /_/ / / / /_/ / /  / / / / /
 \__,_/\__, /\___/_/ /_/\__/_/_/  \__,_/_/  /_/ /_/ /_/
      /____/
                 Proxmox LXC Helper (unified menu)
              github.com/Exploitacious/agentfarm

EOF
}

# -- Preflight ----------------------------------------------------------------
preflight_checks() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "This script must be run as root on the Proxmox host."
    exit 1
  fi

  if ! command -v pveversion &>/dev/null; then
    msg_error "Proxmox VE not detected. Run this on your Proxmox host."
    exit 1
  fi

  if ! command -v pct &>/dev/null; then
    msg_error "pct command not found. Is pve-container installed?"
    exit 1
  fi

  for cmd in dialog jq; do
    if ! command -v "$cmd" &>/dev/null; then
      msg_info "Installing ${cmd}..."
      apt-get update -qq && apt-get install -y -qq "$cmd" >/dev/null 2>&1
      if ! command -v "$cmd" &>/dev/null; then
        msg_error "Failed to install ${cmd}. Cannot continue."
        exit 1
      fi
      msg_ok "${cmd} installed"
    fi
  done

  msg_ok "Preflight checks passed"
}

# -- Bot Type Selector --------------------------------------------------------
select_bot_type() {
  BOT_TYPE=$(dialog --title "Container Type" \
    --menu "What kind of container do you want to provision?" 14 65 4 \
    "openclaw" "OpenClaw agent (Node.js, full install + post-wizard)" \
    "hermes"   "Hermes agent (Python, Nous Research — Phase 3 stub)" \
    "standard" "Standard LXC (no bot install — bare Ubuntu container)" \
    3>&1 1>&2 2>&3) || exit 1

  msg_ok "Container type: ${BOT_TYPE}"
}

# -- OS Selector --------------------------------------------------------------
select_os() {
  OS_VERSION=$(dialog --title "Ubuntu Release" \
    --menu "Choose the Ubuntu release for this container:" 13 60 4 \
    "26.04" "Ubuntu 26.04 LTS (newest LTS, recommended)" \
    "24.04" "Ubuntu 24.04 LTS (mature, well-tested)" \
    "25.04" "Ubuntu 25.04 (interim, 9-month support)" \
    3>&1 1>&2 2>&3) || exit 1

  msg_ok "Ubuntu release: ${OS_VERSION}"
}

# -- Storage Selection --------------------------------------------------------
select_storage() {
  local STORAGE_LIST
  STORAGE_LIST=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}')

  if [[ -z "$STORAGE_LIST" ]]; then
    msg_error "No storage pools found that support container templates."
    exit 1
  fi

  local STORAGE_COUNT
  STORAGE_COUNT=$(echo "$STORAGE_LIST" | wc -l)

  if [[ "$STORAGE_COUNT" -eq 1 ]]; then
    TEMPLATE_STORAGE=$(echo "$STORAGE_LIST" | head -1)
    msg_ok "Using storage: $TEMPLATE_STORAGE"
  else
    local MENU_OPTIONS=()
    while IFS= read -r storage; do
      MENU_OPTIONS+=("$storage" "")
    done <<< "$STORAGE_LIST"

    TEMPLATE_STORAGE=$(dialog --title "Storage Selection" \
      --menu "Select storage for the container template:" 12 50 6 \
      "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3) || exit 1
  fi

  local ROOTFS_STORAGE_LIST
  ROOTFS_STORAGE_LIST=$(pvesm status -content rootdir,images 2>/dev/null | awk 'NR>1 {print $1}')

  if [[ -z "$ROOTFS_STORAGE_LIST" ]]; then
    ROOTFS_STORAGE="$TEMPLATE_STORAGE"
  else
    local ROOTFS_COUNT
    ROOTFS_COUNT=$(echo "$ROOTFS_STORAGE_LIST" | wc -l)

    if [[ "$ROOTFS_COUNT" -eq 1 ]]; then
      ROOTFS_STORAGE=$(echo "$ROOTFS_STORAGE_LIST" | head -1)
    else
      local ROOTFS_MENU=()
      while IFS= read -r storage; do
        ROOTFS_MENU+=("$storage" "")
      done <<< "$ROOTFS_STORAGE_LIST"

      ROOTFS_STORAGE=$(dialog --title "Rootfs Storage" \
        --menu "Select storage for the container rootfs:" 12 50 6 \
        "${ROOTFS_MENU[@]}" 3>&1 1>&2 2>&3) || exit 1
    fi
  fi

  msg_ok "Template storage: $TEMPLATE_STORAGE | Rootfs storage: $ROOTFS_STORAGE"
}

# -- Template Download --------------------------------------------------------
# Args: $1 = storage pool, $2 = OS version (e.g. "26.04")
ensure_template() {
  local TEMPLATE_STORAGE="$1"
  local OS_VERSION="$2"
  local OS_REGEX="ubuntu-${OS_VERSION//./\\.}-standard"
  local TEMPLATE_NAME
  local TEMPLATE_PATH

  TEMPLATE_PATH=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -oP "${OS_REGEX}.*\.tar\.(zst|gz)" | head -1 || true)

  if [[ -z "$TEMPLATE_PATH" ]]; then
    msg_info "Downloading Ubuntu ${OS_VERSION} template..." >&2
    pveam update >/dev/null 2>&1

    TEMPLATE_NAME=$(pveam available --section system 2>/dev/null | grep -oP "${OS_REGEX}.*\.tar\.(zst|gz)" | head -1 || true)

    if [[ -z "$TEMPLATE_NAME" ]]; then
      msg_error "Ubuntu ${OS_VERSION} template not found in pveam." >&2
      msg_error "Run 'pveam available --section system | grep ubuntu-${OS_VERSION}' to check." >&2
      exit 1
    fi

    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" >/dev/null 2>&1
    msg_ok "Template downloaded: $TEMPLATE_NAME" >&2
  else
    TEMPLATE_NAME="$TEMPLATE_PATH"
    msg_ok "Template found: $TEMPLATE_NAME" >&2
  fi

  echo "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
}

# -- Next Available CTID ------------------------------------------------------
get_next_ctid() {
  pvesh get /cluster/nextid 2>/dev/null | tr -d '"'
}

# -- Sizing: Simple Mode ------------------------------------------------------
configure_simple() {
  CT_ID=$(get_next_ctid)
  local DEFAULT_HOSTNAME
  case "$BOT_TYPE" in
    openclaw) DEFAULT_HOSTNAME="openclaw" ;;
    hermes)   DEFAULT_HOSTNAME="hermes"   ;;
    standard) DEFAULT_HOSTNAME="ubuntu"   ;;
  esac

  CT_CPU=2
  CT_RAM=4096
  CT_DISK=20
  CT_BRIDGE="vmbr0"
  CT_VLAN=""
  CT_IP="dhcp"
  CT_GW=""
  CT_DNS=""
  CT_SSH_KEY=""

  CT_HOSTNAME=$(dialog --title "Container Hostname" \
    --inputbox "Hostname for this ${BOT_TYPE} container:" \
    10 60 "$DEFAULT_HOSTNAME" 3>&1 1>&2 2>&3) || exit 1

  local USE_CTID
  USE_CTID=$(dialog --title "Container ID" \
    --inputbox "Container ID (next available: ${CT_ID}):\nPress Enter to accept default." \
    10 50 "$CT_ID" 3>&1 1>&2 2>&3) || exit 1

  [[ -n "$USE_CTID" ]] && CT_ID="$USE_CTID"
}

# -- Sizing: Advanced Mode ----------------------------------------------------
configure_advanced() {
  CT_ID=$(get_next_ctid)

  CT_ID=$(dialog --title "Container ID" \
    --inputbox "Container ID (next available: ${CT_ID}):" \
    8 50 "$CT_ID" 3>&1 1>&2 2>&3) || exit 1

  if pct status "$CT_ID" >/dev/null 2>&1; then
    msg_error "Container ID ${CT_ID} already exists!"
    exit 1
  fi

  local DEFAULT_HOSTNAME
  case "$BOT_TYPE" in
    openclaw) DEFAULT_HOSTNAME="openclaw" ;;
    hermes)   DEFAULT_HOSTNAME="hermes"   ;;
    standard) DEFAULT_HOSTNAME="ubuntu"   ;;
  esac

  CT_HOSTNAME=$(dialog --title "Hostname" \
    --inputbox "Hostname for this container:" \
    8 50 "$DEFAULT_HOSTNAME" 3>&1 1>&2 2>&3) || exit 1

  CT_CPU=$(dialog --title "CPU Cores" --inputbox "Number of CPU cores:" 8 50 "2" 3>&1 1>&2 2>&3) || exit 1
  CT_RAM=$(dialog --title "RAM (MB)" --inputbox "RAM in megabytes:" 8 50 "4096" 3>&1 1>&2 2>&3) || exit 1
  CT_DISK=$(dialog --title "Disk Size (GB)" --inputbox "Root disk size in gigabytes:" 8 50 "20" 3>&1 1>&2 2>&3) || exit 1
  CT_BRIDGE=$(dialog --title "Network Bridge" --inputbox "Network bridge:" 8 50 "vmbr0" 3>&1 1>&2 2>&3) || exit 1
  CT_VLAN=$(dialog --title "VLAN Tag (optional)" --inputbox "VLAN tag (leave empty for none):" 8 50 "" 3>&1 1>&2 2>&3) || exit 1

  local NET_MODE
  NET_MODE=$(dialog --title "Network Mode" \
    --menu "IP addressing:" 12 50 3 \
    "dhcp"   "Automatic (DHCP)" \
    "static" "Static IP" \
    3>&1 1>&2 2>&3) || exit 1

  if [[ "$NET_MODE" == "static" ]]; then
    CT_IP=$(dialog --title "Static IP" --inputbox "IP address with CIDR (e.g., 192.168.1.100/24):" 8 50 "" 3>&1 1>&2 2>&3) || exit 1
    CT_GW=$(dialog --title "Gateway" --inputbox "Default gateway:" 8 50 "" 3>&1 1>&2 2>&3) || exit 1
    CT_DNS=$(dialog --title "DNS Server" --inputbox "DNS server (leave empty for gateway):" 8 50 "" 3>&1 1>&2 2>&3) || exit 1
  else
    CT_IP="dhcp"; CT_GW=""; CT_DNS=""
  fi

  CT_SSH_KEY=$(dialog --title "SSH Public Key (optional)" \
    --inputbox "Path to SSH public key (leave empty to skip):" \
    8 60 "" 3>&1 1>&2 2>&3) || exit 1
}

# -- Standard-mode feature checkboxes (no bot install) ------------------------
configure_standard_features() {
  local SELECTED
  SELECTED=$(dialog --title "Container Features" \
    --checklist "Toggle features for this Standard LXC (Space to toggle):" 13 65 4 \
    "nesting" "Container nesting (Docker, nested LXC, snap)" "on" \
    "tun"     "/dev/net/tun (VPN, Tailscale)" "off" \
    3>&1 1>&2 2>&3) || exit 1

  FEATURE_NESTING=0
  FEATURE_TUN=0
  for f in $SELECTED; do
    case "$f" in
      nesting|\"nesting\") FEATURE_NESTING=1 ;;
      tun|\"tun\")         FEATURE_TUN=1 ;;
    esac
  done

  msg_ok "Standard features: nesting=${FEATURE_NESTING} tun=${FEATURE_TUN}"
}

# -- Build the Container ------------------------------------------------------
build_container() {
  local TEMPLATE_REF
  TEMPLATE_REF=$(ensure_template "$TEMPLATE_STORAGE" "$OS_VERSION")

  msg_info "Creating LXC container ${CT_ID} (${CT_HOSTNAME})..."

  local NET_STRING="name=eth0,bridge=${CT_BRIDGE}"
  if [[ "$CT_IP" == "dhcp" ]]; then
    NET_STRING+=",ip=dhcp"
  else
    NET_STRING+=",ip=${CT_IP}"
    [[ -n "$CT_GW" ]] && NET_STRING+=",gw=${CT_GW}"
  fi
  [[ -n "${CT_VLAN:-}" ]] && NET_STRING+=",tag=${CT_VLAN}"

  # Default features for bot containers: nesting + keyctl on (LXC needs these for
  # systemd-user services + Tailscale). Standard mode reads from the checkbox.
  local FEATURES_STRING="nesting=1,keyctl=1"
  local INJECT_TUN=1
  if [[ "$BOT_TYPE" == "standard" ]]; then
    FEATURES_STRING=""
    [[ "$FEATURE_NESTING" == "1" ]] && FEATURES_STRING+="nesting=1,keyctl=1"
    INJECT_TUN="$FEATURE_TUN"
  fi

  local ROOT_PW="agentfarm"

  local PCT_CMD=(
    pct create "$CT_ID" "$TEMPLATE_REF"
    --hostname "$CT_HOSTNAME"
    --password "$ROOT_PW"
    --cores "$CT_CPU"
    --memory "$CT_RAM"
    --rootfs "${ROOTFS_STORAGE}:${CT_DISK}"
    --net0 "$NET_STRING"
    --unprivileged 1
    --ostype ubuntu
    --start 0
    --onboot 1
  )

  [[ -n "$FEATURES_STRING" ]] && PCT_CMD+=(--features "$FEATURES_STRING")
  [[ -n "${CT_DNS:-}" ]] && PCT_CMD+=(--nameserver "$CT_DNS")
  [[ -n "${CT_SSH_KEY:-}" && -f "${CT_SSH_KEY:-}" ]] && PCT_CMD+=(--ssh-public-keys "$CT_SSH_KEY")

  if ! "${PCT_CMD[@]}" 2>&1; then
    msg_error "pct create failed. Check the error above."
    exit 1
  fi
  msg_ok "Container ${CT_ID} created"

  # Description + tags
  local DESC TAGS
  case "$BOT_TYPE" in
    openclaw) DESC="OpenClaw AI Agent - Created by agentfarm pve-helper"; TAGS="openclaw;agentfarm" ;;
    hermes)   DESC="Hermes AI Agent - Created by agentfarm pve-helper";   TAGS="hermes;agentfarm" ;;
    standard) DESC="Standard LXC - Created by agentfarm pve-helper";      TAGS="agentfarm" ;;
  esac
  pct set "$CT_ID" --description "$DESC" --tags "$TAGS" 2>/dev/null || true

  # Tun injection (cgroup) — for bot containers always, Standard if checked
  if [[ "$INJECT_TUN" == "1" ]]; then
    msg_info "Injecting cgroup config for /dev/net/tun..."
    local LXC_CONF="/etc/pve/lxc/${CT_ID}.conf"
    if ! grep -q "lxc.cgroup2.devices.allow: c 10:200 rwm" "$LXC_CONF" 2>/dev/null; then
      cat >> "$LXC_CONF" <<CGROUP

# agentfarm: Allow /dev/net/tun for Tailscale / VPN
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
CGROUP
    fi
    msg_ok "cgroup config injected"
  fi

  msg_info "Starting container ${CT_ID}..."
  pct start "$CT_ID"

  local RETRIES=0
  while [[ "$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}')" != "running" ]]; do
    sleep 1
    RETRIES=$((RETRIES + 1))
    if [[ $RETRIES -ge 30 ]]; then
      msg_error "Container failed to start within 30 seconds."
      exit 1
    fi
  done
  msg_ok "Container ${CT_ID} is running"

  msg_info "Waiting for systemd to initialize..."
  RETRIES=0
  while ! pct exec "$CT_ID" -- systemctl is-system-running --quiet 2>/dev/null; do
    local SYS_STATE
    SYS_STATE=$(pct exec "$CT_ID" -- systemctl is-system-running 2>/dev/null || echo "starting")
    if [[ "$SYS_STATE" == "running" || "$SYS_STATE" == "degraded" ]]; then
      break
    fi
    sleep 2
    RETRIES=$((RETRIES + 1))
    if [[ $RETRIES -ge 30 ]]; then
      msg_warn "systemd not fully ready after 60s. Continuing anyway..."
      break
    fi
  done
  msg_ok "systemd initialized"

  if [[ "$CT_IP" == "dhcp" ]]; then
    msg_info "Waiting for network (DHCP)..."
    RETRIES=0
    while ! pct exec "$CT_ID" -- ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; do
      sleep 2
      RETRIES=$((RETRIES + 1))
      if [[ $RETRIES -ge 30 ]]; then
        msg_warn "Network not reachable after 60s. Continuing anyway..."
        break
      fi
    done
    msg_ok "Network is up"
  fi
}

# -- File Resolver: local repo or remote --------------------------------------
resolve_file() {
  local FILENAME="$1"
  local LOCAL_PATH="$2"
  local REMOTE_URL="$3"
  local DEST="$4"

  if [[ -f "$LOCAL_PATH" ]]; then
    cp "$LOCAL_PATH" "$DEST"
  else
    msg_info "Fetching ${FILENAME} from GitHub..."
    if ! curl -fsSL "$REMOTE_URL" -o "$DEST" 2>/dev/null; then
      msg_error "Failed to download ${FILENAME} from ${REMOTE_URL}"
      return 1
    fi
  fi
  return 0
}

# -- Dispatch: push bot's install.sh + templates and run it -------------------
# Args: $1 = bot subdir name (e.g. "openclaw"), $@2 = template basenames
dispatch_bot_install() {
  local BOT_DIR="$1"
  shift
  local TEMPLATES=("$@")

  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd 2>/dev/null || echo "")"

  local STAGE_DIR
  STAGE_DIR=$(mktemp -d /tmp/agentfarm.XXXXXX)
  trap "rm -rf ${STAGE_DIR}" EXIT

  # Resolve install.sh
  local LOCAL_INSTALL="${SCRIPT_DIR:+${SCRIPT_DIR}/${BOT_DIR}/}install.sh"
  resolve_file "${BOT_DIR}/install.sh" \
    "$LOCAL_INSTALL" \
    "${REPO_RAW}/${BOT_DIR}/install.sh" \
    "${STAGE_DIR}/install.sh" \
    || exit 1
  chmod +x "${STAGE_DIR}/install.sh"

  msg_info "Pushing ${BOT_DIR} install script into container..."
  pct push "$CT_ID" "${STAGE_DIR}/install.sh" /tmp/install.sh
  pct exec "$CT_ID" -- chmod +x /tmp/install.sh
  msg_ok "Install script pushed"

  # Resolve and push templates
  for tpl in "${TEMPLATES[@]}"; do
    local LOCAL_TPL="${SCRIPT_DIR:+${SCRIPT_DIR}/${BOT_DIR}/templates/}${tpl}"
    local STAGED="${STAGE_DIR}/${tpl}"

    if resolve_file "$tpl" "$LOCAL_TPL" "${REPO_RAW}/${BOT_DIR}/templates/${tpl}" "$STAGED"; then
      if [[ "$tpl" == *.json.tpl ]]; then
        if ! jq empty < "$STAGED" >/dev/null 2>&1; then
          msg_error "${tpl} is not valid JSON. Fix it before proceeding."
          exit 1
        fi
      fi
      pct push "$CT_ID" "$STAGED" "/tmp/${tpl}"
      msg_ok "Pushed template: ${tpl}"
    else
      msg_warn "Could not resolve ${tpl} (local or remote). Skipping."
    fi
  done

  msg_info "Running install script inside container (this takes a few minutes)..."
  echo ""
  pct exec "$CT_ID" -- env PUSHED_BY_HOST=1 bash /tmp/install.sh
}

# -- Summaries ----------------------------------------------------------------
print_summary_openclaw() {
  local CT_IPADDR
  CT_IPADDR=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

  echo ""
  echo "============================================================================="
  echo -e " ${GN}OpenClaw container ${CT_ID} is ready!${CL}"
  echo "============================================================================="
  echo "  Hostname:    ${CT_HOSTNAME}    OS: Ubuntu ${OS_VERSION}"
  echo "  Container:   ${CT_ID}          IP: ${CT_IPADDR}"
  echo "  Resources:   ${CT_CPU} cores / ${CT_RAM} MB / ${CT_DISK} GB"
  echo ""
  echo "  Next steps:"
  echo -e "    1. Reboot:   ${YW}pct reboot ${CT_ID}${CL}"
  echo "    2. SSH in:   ssh claw@${CT_IPADDR}  (password: openclaw)"
  echo -e "    3. Password: ${RD}passwd${CL}  (change immediately)"
  echo -e "    4. Wizard:   ${GN}bash ~/agentfarm/openclaw/postinstall.sh${CL}"
  echo "============================================================================="
}

print_summary_hermes() {
  local CT_IPADDR
  CT_IPADDR=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

  echo ""
  echo "============================================================================="
  echo -e " ${YW}Hermes container ${CT_ID} created (install path is Phase 3 stub).${CL}"
  echo "============================================================================="
  echo "  Hostname:    ${CT_HOSTNAME}    OS: Ubuntu ${OS_VERSION}"
  echo "  Container:   ${CT_ID}          IP: ${CT_IPADDR}"
  echo "  Resources:   ${CT_CPU} cores / ${CT_RAM} MB / ${CT_DISK} GB"
  echo ""
  echo -e "  ${YW}Hermes install scripts are not yet built.${CL}"
  echo "  For now, install Hermes manually inside the container:"
  echo -e "    ${BL}pct enter ${CT_ID}${CL}"
  echo "    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash"
  echo ""
  echo "  Once Phase 3 lands, re-run this helper and it will deploy Hermes end-to-end."
  echo "============================================================================="
}

print_summary_standard() {
  local CT_IPADDR
  CT_IPADDR=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

  echo ""
  echo "============================================================================="
  echo -e " ${GN}Standard LXC ${CT_ID} is ready!${CL}"
  echo "============================================================================="
  echo "  Hostname:    ${CT_HOSTNAME}    OS: Ubuntu ${OS_VERSION}"
  echo "  Container:   ${CT_ID}          IP: ${CT_IPADDR}"
  echo "  Resources:   ${CT_CPU} cores / ${CT_RAM} MB / ${CT_DISK} GB"
  echo "  Features:    nesting=${FEATURE_NESTING} tun=${FEATURE_TUN}"
  echo ""
  echo "  Container default password: ${RD}agentfarm${CL}"
  echo "  Enter the container: ${BL}pct enter ${CT_ID}${CL}"
  echo "============================================================================="
}

# =============================================================================
# Main
# =============================================================================
main() {
  header_info
  preflight_checks
  select_bot_type
  select_storage
  select_os

  local MODE
  MODE=$(dialog --title "Setup Mode" \
    --menu "Choose setup mode:" 12 60 2 \
    "simple"   "Quick setup with sane defaults (recommended)" \
    "advanced" "Full control over all container settings" \
    3>&1 1>&2 2>&3) || exit 1

  case "$MODE" in
    simple)   configure_simple   ;;
    advanced) configure_advanced ;;
  esac

  FEATURE_NESTING=1
  FEATURE_TUN=1
  if [[ "$BOT_TYPE" == "standard" ]]; then
    configure_standard_features
  fi

  # Confirmation dialog
  local CONFIRM_TEXT="Create container with these settings?\n\n"
  CONFIRM_TEXT+="  Type:          ${BOT_TYPE}\n"
  CONFIRM_TEXT+="  Container ID:  ${CT_ID}\n"
  CONFIRM_TEXT+="  Hostname:      ${CT_HOSTNAME}\n"
  CONFIRM_TEXT+="  OS:            Ubuntu ${OS_VERSION}\n"
  CONFIRM_TEXT+="  CPU Cores:     ${CT_CPU}\n"
  CONFIRM_TEXT+="  RAM:           ${CT_RAM} MB\n"
  CONFIRM_TEXT+="  Disk:          ${CT_DISK} GB\n"
  CONFIRM_TEXT+="  Network:       ${CT_IP}\n"
  CONFIRM_TEXT+="  Bridge:        ${CT_BRIDGE}\n"
  [[ -n "${CT_VLAN:-}" ]] && CONFIRM_TEXT+="  VLAN:          ${CT_VLAN}\n"
  CONFIRM_TEXT+="\n  Features: nesting=${FEATURE_NESTING} tun=${FEATURE_TUN}\n"

  dialog --title "Confirm" --yesno "$CONFIRM_TEXT" 20 60 || exit 1

  clear
  header_info
  build_container

  case "$BOT_TYPE" in
    openclaw)
      dispatch_bot_install "openclaw" "openclaw.json.tpl" "soul.md.tpl" "agents.md.tpl"
      print_summary_openclaw
      ;;
    hermes)
      msg_warn "Hermes install path is a Phase 3 stub — container created, but no bot install."
      print_summary_hermes
      ;;
    standard)
      print_summary_standard
      ;;
  esac
}

main "$@"
