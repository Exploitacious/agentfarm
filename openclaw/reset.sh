#!/usr/bin/env bash

# =============================================================================
# OpenClaw Reset Script
#
# Wipes workspace (SOUL.md, AGENTS.md, USER.md), memory, and sessions while
# preserving all API keys, provider credentials, and config settings.
# Re-applies templates from the helper repo and launches onboard to re-hatch.
#
# Usage:
#   Interactive:  bash ~/agentfarm/openclaw/reset.sh
#   Scripted:     bash ~/agentfarm/openclaw/reset.sh --confirm --skip-hatch
# =============================================================================

set -euo pipefail

# -- Colors & Formatting -------------------------------------------------------
GN="\e[32m"; RD="\e[31m"; BL="\e[36m"; YW="\e[33m"; DM="\e[2m"; CL="\e[0m"
CM="${GN}\xE2\x9C\x94${CL}"; CROSS="${RD}\xE2\x9C\x98${CL}"

msg_ok()    { printf " ${CM} ${GN}%s${CL}\n" "$1"; }
msg_error() { printf " ${CROSS} ${RD}%s${CL}\n" "$1"; }
msg_info()  { printf "   ${BL}%s${CL}\n" "$1"; }
msg_warn()  { printf "   ${YW}%s${CL}\n" "$1"; }
msg_step()  { printf "\n ${GN}>>>${CL} %s\n" "$1"; }
msg_dim()   { printf "   ${DM}%s${CL}\n" "$1"; }

# -- Ensure PATH ---------------------------------------------------------------
export PATH="${HOME}/.npm-global/bin:${HOME}/.local/share/pnpm:${PATH}"
NVM_NODE_DIR="${HOME}/.nvm/versions/node"
if [[ -d "$NVM_NODE_DIR" ]]; then
  NVM_LATEST=$(ls "$NVM_NODE_DIR" 2>/dev/null | sort -V | tail -1)
  [[ -n "$NVM_LATEST" ]] && export PATH="${NVM_NODE_DIR}/${NVM_LATEST}/bin:${PATH}"
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# -- Config --------------------------------------------------------------------
OC_DIR="${HOME}/.openclaw"
OC_CONFIG="${OC_DIR}/openclaw.json"
OC_ENV="${OC_DIR}/.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
REPO_RAW="https://raw.githubusercontent.com/Exploitacious/agentfarm/refs/heads/master"

# -- Parse flags ---------------------------------------------------------------
CONFIRMED=false
SKIP_HATCH=false
KEEP_SOUL=false
FULL_RESET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)       CONFIRMED=true; shift ;;
    --skip-hatch)    SKIP_HATCH=true; shift ;;
    --keep-soul)     KEEP_SOUL=true; shift ;;
    --full)          FULL_RESET=true; shift ;;
    --help|-h)
      echo "Usage: bash reset.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --confirm       Skip confirmation prompt"
      echo "  --skip-hatch    Don't launch onboard after reset"
      echo "  --keep-soul     Preserve SOUL.md (only reset memory/sessions)"
      echo "  --full          Also reset openclaw.json to template defaults"
      echo "                  (preserves API keys in .env and auth-profiles)"
      echo "  --help          Show this help"
      exit 0
      ;;
    *)
      msg_error "Unknown flag: $1"
      exit 1
      ;;
  esac
done

# -- Preflight checks ---------------------------------------------------------
if [[ "$(id -u)" == "0" ]]; then
  msg_error "Do not run this as root. Run as the claw user."
  exit 1
fi

if [[ ! -d "$OC_DIR" ]]; then
  msg_error "OpenClaw directory not found at ${OC_DIR}"
  exit 1
fi

if ! command -v openclaw &>/dev/null; then
  msg_error "openclaw command not found in PATH"
  exit 1
fi

# -- Resolve templates ---------------------------------------------------------
# Try local repo first, fall back to GitHub
resolve_template() {
  local NAME="$1"
  if [[ -f "${TEMPLATE_DIR}/${NAME}" ]]; then
    cat "${TEMPLATE_DIR}/${NAME}"
  elif curl -fsSL "${REPO_RAW}/openclaw/templates/${NAME}" 2>/dev/null; then
    : # curl already output to stdout
  else
    msg_error "Cannot resolve template: ${NAME}"
    return 1
  fi
}

# -- Show what will be wiped ---------------------------------------------------
echo ""
echo -e "${YW}============================================${CL}"
echo -e "${YW}  OpenClaw Reset${CL}"
echo -e "${YW}============================================${CL}"
echo ""

msg_info "This will:"
if ! $KEEP_SOUL; then
  echo -e "   ${RD}\xe2\x80\xa2${CL} Remove SOUL.md and IDENTITY.md (regenerated during re-hatch)"
fi
echo -e "   ${RD}\xe2\x80\xa2${CL} Remove AGENTS.md, TOOLS.md, BOOTSTRAP.md (regenerated during re-hatch)"
echo -e "   ${RD}\xe2\x80\xa2${CL} Reset USER.md to blank"
echo -e "   ${RD}\xe2\x80\xa2${CL} Wipe all memory (LanceDB vector store + markdown logs)"
echo -e "   ${RD}\xe2\x80\xa2${CL} Wipe all sessions (conversation history)"
echo -e "   ${RD}\xe2\x80\xa2${CL} Wipe workspace skills (memory-lancedb-hybrid plugin data)"
if $FULL_RESET; then
  echo -e "   ${RD}\xe2\x80\xa2${CL} Reset openclaw.json to template defaults"
fi
echo ""
msg_info "This will KEEP:"
echo -e "   ${GN}\xe2\x80\xa2${CL} API keys (.env)"
echo -e "   ${GN}\xe2\x80\xa2${CL} Provider credentials (auth-profiles.json)"
echo -e "   ${GN}\xe2\x80\xa2${CL} Gateway token and Telegram bot token"
if ! $FULL_RESET; then
  echo -e "   ${GN}\xe2\x80\xa2${CL} All openclaw.json settings (models, concurrency, hooks, etc.)"
fi
if $KEEP_SOUL; then
  echo -e "   ${GN}\xe2\x80\xa2${CL} SOUL.md (personality preserved)"
fi
echo ""

if ! $CONFIRMED; then
  printf "   ${RD}Are you sure? This cannot be undone. [y/N]${CL}: "
  read -r CONFIRM_INPUT
  if [[ "${CONFIRM_INPUT,,}" != "y" && "${CONFIRM_INPUT,,}" != "yes" ]]; then
    msg_info "Cancelled."
    exit 0
  fi
fi

# -- Create backup before reset ------------------------------------------------
msg_step "Step 1/5: Backup"
BACKUP_DIR="${HOME}/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/openclaw-pre-reset-$(date +%Y%m%d-%H%M%S).tar.gz"

msg_info "Backing up current state..."
tar -czf "$BACKUP_FILE" \
  -C "$HOME" \
  .openclaw/openclaw.json \
  .openclaw/.env \
  .openclaw/workspace/ \
  .openclaw/agents/ \
  2>/dev/null || true

if [[ -f "$BACKUP_FILE" ]]; then
  msg_ok "Backup saved: ${BACKUP_FILE}"
else
  msg_warn "Backup may be incomplete"
fi

# -- Stop gateway --------------------------------------------------------------
msg_step "Step 2/5: Stop gateway"
systemctl --user stop openclaw-gateway.service 2>/dev/null || true
sleep 1
msg_ok "Gateway stopped"

# -- Wipe sessions and memory --------------------------------------------------
msg_step "Step 3/5: Wipe data"

# Sessions
if [[ -d "${OC_DIR}/sessions" ]]; then
  rm -rf "${OC_DIR}/sessions"
  msg_ok "Sessions wiped"
else
  msg_dim "No sessions directory found"
fi

# Memory (LanceDB + markdown)
if [[ -d "${OC_DIR}/memory" ]]; then
  rm -rf "${OC_DIR}/memory"
  msg_ok "Memory wiped"
else
  msg_dim "No memory directory found"
fi

# Agent session data
find "${OC_DIR}/agents" -type d -name "sessions" -exec rm -rf {} + 2>/dev/null || true
msg_ok "Agent session data wiped"

# Memory plugin — move out of workspace before hatch to keep workspace clean
# (Any content in workspace/ triggers hasUserContent, blocking BOOTSTRAP.md creation)
MEMORY_PLUGIN_STASH=""
if [[ -d "${OC_DIR}/workspace/skills/memory-lancedb-hybrid" ]]; then
  # Wipe plugin data files first
  find "${OC_DIR}/workspace/skills/memory-lancedb-hybrid" \
    -name "*.lance" -o -name "*.idx" -o -name "*.manifest" \
    -exec rm -f {} + 2>/dev/null || true
  msg_ok "Memory plugin data wiped"

  # Stash plugin code outside workspace so hatch sees a clean workspace
  MEMORY_PLUGIN_STASH="/tmp/openclaw-memory-plugin-stash-$$"
  mv "${OC_DIR}/workspace/skills/memory-lancedb-hybrid" "$MEMORY_PLUGIN_STASH"
  msg_ok "Memory plugin stashed for re-install after hatch"

  # Clean up empty skills/ dir if nothing else is in it
  rmdir "${OC_DIR}/workspace/skills" 2>/dev/null || true
fi

# -- Re-apply templates --------------------------------------------------------
msg_step "Step 4/5: Apply templates"

WORKSPACE_DIR="${OC_DIR}/workspace"
mkdir -p "$WORKSPACE_DIR"

# Remove workspace identity files so hatching can regenerate them
if ! $KEEP_SOUL; then
  rm -f "${WORKSPACE_DIR}/SOUL.md" "${WORKSPACE_DIR}/IDENTITY.md"
  msg_ok "SOUL.md and IDENTITY.md removed (will be regenerated during hatch)"
fi

rm -f "${WORKSPACE_DIR}/AGENTS.md" "${WORKSPACE_DIR}/TOOLS.md" "${WORKSPACE_DIR}/BOOTSTRAP.md"
msg_ok "AGENTS.md, TOOLS.md, BOOTSTRAP.md removed (will be regenerated during hatch)"

# USER.md — remove before hatch (recreated after)
rm -f "${WORKSPACE_DIR}/USER.md"
msg_ok "USER.md removed (will be recreated after hatch)"

# Full config reset (optional)
if $FULL_RESET; then
  # Save values we want to preserve
  SAVED_GW_TOKEN=$(jq -r '.gateway.auth.token // ""' "$OC_CONFIG" 2>/dev/null)
  SAVED_TG_TOKEN=$(jq -r '.channels.telegram.botToken // ""' "$OC_CONFIG" 2>/dev/null)
  SAVED_TG_UID=$(jq -r '.channels.telegram.dmPolicy // ""' "$OC_CONFIG" 2>/dev/null)
  SAVED_TS_DNS=$(jq -r '.gateway.remote.url // ""' "$OC_CONFIG" 2>/dev/null)

  # Apply template
  CONFIG_CONTENT=$(resolve_template "openclaw.json.tpl" 2>/dev/null) || true
  if [[ -n "$CONFIG_CONTENT" ]]; then
    echo "$CONFIG_CONTENT" > "$OC_CONFIG"
    chmod 600 "$OC_CONFIG"

    # Restore preserved values
    [[ -n "$SAVED_GW_TOKEN" ]] && \
      jq --arg t "$SAVED_GW_TOKEN" '.gateway.auth.token = $t' "$OC_CONFIG" > "${OC_CONFIG}.tmp" && \
      mv "${OC_CONFIG}.tmp" "$OC_CONFIG"
    [[ -n "$SAVED_TG_TOKEN" && "$SAVED_TG_TOKEN" != "__TELEGRAM_BOT_TOKEN__" ]] && \
      jq --arg t "$SAVED_TG_TOKEN" '.channels.telegram.botToken = $t' "$OC_CONFIG" > "${OC_CONFIG}.tmp" && \
      mv "${OC_CONFIG}.tmp" "$OC_CONFIG"
    [[ -n "$SAVED_TS_DNS" ]] && \
      jq --arg u "$SAVED_TS_DNS" '.gateway.remote.url = $u' "$OC_CONFIG" > "${OC_CONFIG}.tmp" && \
      mv "${OC_CONFIG}.tmp" "$OC_CONFIG"

    chmod 600 "$OC_CONFIG"
    msg_ok "openclaw.json reset to template (tokens preserved)"
  else
    msg_warn "Could not resolve openclaw.json.tpl — config left unchanged"
  fi
fi

# -- Restart and hatch ---------------------------------------------------------
msg_step "Step 5/5: Restart and re-hatch"

# Run doctor to re-wire hooks
msg_info "Running openclaw doctor --fix..."
openclaw doctor --fix 2>&1 | tail -5 || true
msg_ok "Doctor completed"

# Git commit the reset (pre-hatch state)
if [[ -d "${OC_DIR}/.git" ]]; then
  cd "$OC_DIR"
  git add -A 2>/dev/null || true
  git commit -q -m "reset: wiped memory/sessions/personality $(date +%Y-%m-%d)" 2>/dev/null || true
  msg_ok "Reset committed to git"
fi

echo ""
echo -e "${GN}============================================${CL}"
echo -e "${GN}  Reset Complete — Ready to Re-Hatch${CL}"
echo -e "${GN}============================================${CL}"
echo ""
msg_ok "Backup: ${BACKUP_FILE}"
msg_ok "Memory and sessions wiped"
msg_ok "Workspace identity files removed"
echo ""

# -- Hatching helpers ----------------------------------------------------------
BOOTSTRAP_TEMPLATE="${HOME}/.npm-global/lib/node_modules/openclaw/docs/reference/templates/BOOTSTRAP.md"
SAVED_PRIMARY=""
HATCH_MODEL=""

seed_bootstrap() {
  local DEST="${OC_DIR}/workspace/BOOTSTRAP.md"

  if [[ ! -f "$BOOTSTRAP_TEMPLATE" ]]; then
    msg_warn "BOOTSTRAP.md template not found at ${BOOTSTRAP_TEMPLATE}"
    msg_warn "OpenClaw may have moved it. Check: find ~/.npm-global -name BOOTSTRAP.md"
    return 1
  fi

  cp "$BOOTSTRAP_TEMPLATE" "$DEST"
  sed -i '1{/^---$/,/^---$/d}' "$DEST"
  chmod 644 "$DEST"
  msg_ok "BOOTSTRAP.md seeded from OpenClaw template"
}

pick_hatch_model() {
  local CURRENT_PRIMARY
  CURRENT_PRIMARY=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "not set"' "$OC_CONFIG" 2>/dev/null)

  echo ""
  echo -e "   ${GN}========================================${CL}"
  echo -e "   ${GN}  Hatch Model Selection${CL}"
  echo -e "   ${GN}========================================${CL}"
  echo ""
  msg_dim "Hatching requires a model that can follow complex multi-step instructions."
  msg_dim "Your current primary model (${CURRENT_PRIMARY}) will be restored after hatching."
  echo ""
  msg_info "Choose a model for the hatching process:"
  echo ""
  echo -e "  ${GN}1)${CL} opencode-go/glm-5          ${DM}— Recommended. Strong instruction following, included with OpenCode Go.${CL}"
  echo -e "  ${GN}2)${CL} anthropic/claude-sonnet     ${DM}— Best quality hatch. Requires Anthropic API key.${CL}"
  echo -e "  ${GN}3)${CL} openai/gpt-4o              ${DM}— Good alternative. Requires OpenAI API key (you may already have one for embeddings).${CL}"
  echo -e "  ${GN}4)${CL} opencode-go/kimi-k2.5      ${DM}— Your default. May struggle with tool-calling init (known issue #55942).${CL}"
  echo -e "  ${GN}5)${CL} ${CURRENT_PRIMARY}  ${DM}— Keep current model as-is (no swap).${CL}"
  echo -e "  ${GN}6)${CL} Custom                     ${DM}— Enter any model string manually.${CL}"
  echo ""
  printf "   ${BL}Select [1-6, default=1]:${CL} "
  read -r HATCH_CHOICE

  case "${HATCH_CHOICE:-1}" in
    1) HATCH_MODEL="opencode-go/glm-5" ;;
    2) HATCH_MODEL="anthropic/claude-sonnet" ;;
    3) HATCH_MODEL="openai/gpt-4o" ;;
    4) HATCH_MODEL="opencode-go/kimi-k2.5" ;;
    5) HATCH_MODEL="$CURRENT_PRIMARY" ;;
    6)
      printf "   ${BL}Enter model string:${CL} "
      read -r CUSTOM_MODEL
      if [[ -z "$CUSTOM_MODEL" ]]; then
        msg_warn "No model entered — defaulting to opencode-go/glm-5"
        HATCH_MODEL="opencode-go/glm-5"
      else
        HATCH_MODEL="$CUSTOM_MODEL"
      fi
      ;;
    *)
      msg_warn "Invalid choice — defaulting to opencode-go/glm-5"
      HATCH_MODEL="opencode-go/glm-5"
      ;;
  esac

  msg_ok "Hatch model: ${HATCH_MODEL}"
}

swap_model_for_hatch() {
  SAVED_PRIMARY=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // ""' "$OC_CONFIG" 2>/dev/null)

  if [[ -z "$SAVED_PRIMARY" || "$SAVED_PRIMARY" == "null" ]]; then
    return 0
  fi

  if [[ "$SAVED_PRIMARY" == "$HATCH_MODEL" ]]; then
    msg_dim "Primary model is already ${HATCH_MODEL} — no swap needed"
    SAVED_PRIMARY=""
    return 0
  fi

  msg_info "Temporarily setting primary model to ${HATCH_MODEL} for hatching..."
  msg_dim "(Original: ${SAVED_PRIMARY} — will be restored after hatch)"

  jq --arg m "$HATCH_MODEL" '.agents.defaults.model.primary = $m' "$OC_CONFIG" > "${OC_CONFIG}.tmp"
  mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
}

restore_model_after_hatch() {
  if [[ -z "${SAVED_PRIMARY:-}" ]]; then
    return 0
  fi

  msg_info "Restoring primary model to ${SAVED_PRIMARY}..."
  jq --arg m "$SAVED_PRIMARY" '.agents.defaults.model.primary = $m' "$OC_CONFIG" > "${OC_CONFIG}.tmp"
  mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
  msg_ok "Primary model restored: ${SAVED_PRIMARY}"
}

post_hatch_restore() {
  restore_model_after_hatch

  # Restore memory plugin from stash
  if [[ -n "${MEMORY_PLUGIN_STASH:-}" && -d "$MEMORY_PLUGIN_STASH" ]]; then
    mkdir -p "${OC_DIR}/workspace/skills"
    mv "$MEMORY_PLUGIN_STASH" "${OC_DIR}/workspace/skills/memory-lancedb-hybrid"
    msg_ok "Memory plugin restored"
  fi

  # Restart gateway with production model
  msg_info "Restarting gateway..."
  systemctl --user restart openclaw-gateway.service 2>/dev/null || true
  sleep 3

  if systemctl --user is-active openclaw-gateway.service >/dev/null 2>&1; then
    msg_ok "Gateway running"
  else
    msg_warn "Gateway may not have started. Check: systemctl --user status openclaw-gateway.service"
  fi

  # Git commit post-hatch state
  if [[ -d "${OC_DIR}/.git" ]]; then
    cd "$OC_DIR"
    git add -A 2>/dev/null || true
    git commit -q -m "post-hatch: personality created, model restored, plugin reinstated $(date +%Y-%m-%d)" 2>/dev/null || true
    msg_ok "Post-hatch state committed to git"
  fi
}

# -- Hatch or skip -------------------------------------------------------------
if $SKIP_HATCH; then
  msg_info "Starting gateway..."
  systemctl --user start openclaw-gateway.service 2>/dev/null || true
  sleep 3

  # Restore memory plugin even if skipping hatch
  if [[ -n "${MEMORY_PLUGIN_STASH:-}" && -d "$MEMORY_PLUGIN_STASH" ]]; then
    mkdir -p "${OC_DIR}/workspace/skills"
    mv "$MEMORY_PLUGIN_STASH" "${OC_DIR}/workspace/skills/memory-lancedb-hybrid"
    msg_ok "Memory plugin restored"
  fi

  msg_info "Skipped hatching. When ready:"
  echo ""
  echo -e "  ${BL}bash ~/agentfarm/openclaw/postinstall.sh${CL}   (recommended — handles everything)"
  echo ""
  echo -e "  ${DM}Or manually:${CL}"
  echo -e "  ${BL}cp ${BOOTSTRAP_TEMPLATE} ~/.openclaw/workspace/BOOTSTRAP.md${CL}"
  echo -e "  ${BL}openclaw tui --message \"Wake up, my friend!\"${CL}"
  echo ""
  exit 0
fi

echo ""
echo -e "   ${GN}========================================${CL}"
echo -e "   ${GN}  Re-Hatching${CL}"
echo -e "   ${GN}========================================${CL}"
echo ""
msg_dim "The bot will say 'Wake up, my friend...' and walk you through building"
msg_dim "its personality from scratch: name, vibe, SOUL.md, IDENTITY.md."
msg_dim ""
msg_dim "When done, the bot deletes BOOTSTRAP.md on its own. After you exit"
msg_dim "the TUI, the script restores your production model and memory plugin."
msg_dim ""
msg_warn "Do NOT message the bot on Telegram until hatching is complete."
echo ""

printf "   ${BL}Press Enter to hatch (or 's' to skip)${CL}: "
read -r HATCH_REPLY

if [[ "${HATCH_REPLY,,}" != "s" ]]; then

  # 1. Pick hatch model (interactive menu)
  pick_hatch_model

  # 2. Seed BOOTSTRAP.md
  echo ""
  seed_bootstrap || {
    msg_error "Cannot hatch without BOOTSTRAP.md. Fix the template path and re-run."
    # Restore memory plugin before exiting
    if [[ -n "${MEMORY_PLUGIN_STASH:-}" && -d "$MEMORY_PLUGIN_STASH" ]]; then
      mkdir -p "${OC_DIR}/workspace/skills"
      mv "$MEMORY_PLUGIN_STASH" "${OC_DIR}/workspace/skills/memory-lancedb-hybrid"
    fi
    exit 1
  }

  # 3. Swap model
  swap_model_for_hatch

  # 4. Start gateway with hatch model
  msg_info "Starting gateway..."
  systemctl --user start openclaw-gateway.service 2>/dev/null || true
  sleep 3

  # 5. Launch TUI with the hatching message
  echo ""
  msg_ok "Launching TUI — hatching begins..."
  echo ""
  openclaw tui --message "Wake up, my friend!"
  TUI_EXIT=$?
  echo ""

  # 6. Post-hatch restoration
  post_hatch_restore

  if [[ $TUI_EXIT -eq 0 ]]; then
    echo ""
    echo -e "${GN}============================================${CL}"
    echo -e "${GN}  Re-Hatch Complete${CL}"
    echo -e "${GN}============================================${CL}"
    echo ""
  else
    msg_warn "TUI exited with code ${TUI_EXIT}."
  fi
else
  echo ""

  # Restore memory plugin if skipping hatch
  if [[ -n "${MEMORY_PLUGIN_STASH:-}" && -d "$MEMORY_PLUGIN_STASH" ]]; then
    mkdir -p "${OC_DIR}/workspace/skills"
    mv "$MEMORY_PLUGIN_STASH" "${OC_DIR}/workspace/skills/memory-lancedb-hybrid"
    msg_ok "Memory plugin restored"
  fi

  # Start gateway
  msg_info "Starting gateway..."
  systemctl --user start openclaw-gateway.service 2>/dev/null || true
  sleep 3

  msg_info "When ready:"
  echo ""
  echo -e "  ${DM}# Seed bootstrap and launch TUI:${CL}"
  echo -e "  ${BL}cp ${BOOTSTRAP_TEMPLATE} ~/.openclaw/workspace/BOOTSTRAP.md${CL}"
  echo -e "  ${BL}openclaw tui --message \"Wake up, my friend!\"${CL}"
  echo ""
fi
