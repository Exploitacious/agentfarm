#!/usr/bin/env bash

# =============================================================================
# OpenClaw Post-Install Wizard
#
# Run after openclaw/install.sh to complete setup interactively or via flags.
# Handles: AI providers, embeddings key, Telegram bot, Tailscale, onboarding.
#
# Usage:
#   Interactive:  bash postinstall.sh
#   Scripted:     bash postinstall.sh \
#                   --provider opencode-go --provider-key sk-... \
#                   --primary-model opencode-go/kimi-k2.5 \
#                   --fallback-models "opencode-go/minimax-m2.7, opencode-go/glm-5" \
#                   --heartbeat-model opencode-go/minimax-m2.5 \
#                   --openai-key sk-... \
#                   --telegram-token 123456:ABC... \
#                   --telegram-user-id 123456789 \
#                   --tailscale-auth-key tskey-auth-...
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
# Append NVM node if available
NVM_NODE_DIR="${HOME}/.nvm/versions/node"
if [[ -d "$NVM_NODE_DIR" ]]; then
  NVM_LATEST=$(ls "$NVM_NODE_DIR" 2>/dev/null | sort -V | tail -1)
  [[ -n "$NVM_LATEST" ]] && export PATH="${NVM_NODE_DIR}/${NVM_LATEST}/bin:${PATH}"
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

OC_DIR="${HOME}/.openclaw"
OC_CONFIG="${OC_DIR}/openclaw.json"
OC_ENV="${OC_DIR}/.env"
AUTH_PROFILES="${OC_DIR}/agents/main/agent/auth-profiles.json"

# -- Provider registry ---------------------------------------------------------
# Maps menu labels to openclaw onboard --auth-choice values, key flags, and
# example model strings. Order matters (it's the menu order).
#
# Format: "label|auth-choice|key-flag|example-models"
PROVIDER_REGISTRY=(
  "Anthropic (Claude)|anthropic-api-key|--anthropic-api-key|anthropic/claude-sonnet-4-5, anthropic/claude-opus-4-5"
  "Google Gemini|gemini-api-key|--gemini-api-key|gemini/gemini-2.5-flash, gemini/gemini-2.5-pro"
  "OpenAI (GPT)|openai-api-key|--openai-api-key|openai/gpt-5, openai/gpt-5-mini"
  "OpenAI Codex (ChatGPT OAuth)|openai-codex||openai-codex/gpt-5.4, openai-codex/gpt-5.3-codex"
  "OpenRouter|openrouter-api-key|--openrouter-api-key|openrouter/google/gemini-3-flash-preview"
  "OpenCode Zen|opencode-zen|--opencode-zen-api-key|opencode-zen/kimi-k2.5, opencode-zen/glm-5"
  "OpenCode Go|opencode-go|--opencode-go-api-key|opencode-go/kimi-k2.5, opencode-go/minimax-m2.7, opencode-go/minimax-m2.5"
  "Ollama|ollama||ollama/llama4, ollama/qwen3"
  "DeepSeek|deepseek-api-key|--deepseek-api-key|deepseek/deepseek-chat, deepseek/deepseek-reasoner"
  "xAI (Grok)|xai-api-key|--xai-api-key|xai/grok-3, xai/grok-3-mini"
  "Mistral|mistral-api-key|--mistral-api-key|mistral/mistral-large, mistral/codestral"
  "Together AI|together-api-key|--together-api-key|together/meta-llama/Llama-4-Maverick-17Bx128E"
  "LiteLLM proxy|litellm-api-key|--litellm-api-key|litellm/your-model-id"
  "Custom (OpenAI-compat)|custom-api-key|--custom-api-key|custom/your-model-id"
)

# -- Parse flags ---------------------------------------------------------------
# Provider flags are paired: --provider <choice> --provider-key <key>
# Can be repeated for multiple providers.
declare -a CLI_PROVIDERS=()    # auth-choice values
declare -a CLI_PROVIDER_KEYS=() # corresponding keys
PRIMARY_MODEL=""
FALLBACK_MODELS=""
HEARTBEAT_MODEL=""
OPENAI_KEY=""
TELEGRAM_TOKEN=""
TELEGRAM_USER_ID=""
TAILSCALE_AUTH_KEY=""
SKIP_TAILSCALE=false
SKIP_SOUL=false
SKIP_PROVIDERS=false
NON_INTERACTIVE=false
OLLAMA_BASE_URL=""
CUSTOM_BASE_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      CLI_PROVIDERS+=("$2"); shift 2 ;;
    --provider-key)
      CLI_PROVIDER_KEYS+=("$2"); shift 2 ;;
    --primary-model)      PRIMARY_MODEL="$2"; shift 2 ;;
    --fallback-models)    FALLBACK_MODELS="$2"; shift 2 ;;
    --heartbeat-model)    HEARTBEAT_MODEL="$2"; shift 2 ;;
    --openai-key)         OPENAI_KEY="$2"; shift 2 ;;
    --telegram-token)     TELEGRAM_TOKEN="$2"; shift 2 ;;
    --telegram-user-id)   TELEGRAM_USER_ID="$2"; shift 2 ;;
    --tailscale-auth-key) TAILSCALE_AUTH_KEY="$2"; shift 2 ;;
    --ollama-url)         OLLAMA_BASE_URL="$2"; shift 2 ;;
    --custom-base-url)    CUSTOM_BASE_URL="$2"; shift 2 ;;
    --skip-tailscale)     SKIP_TAILSCALE=true; shift ;;
    --skip-soul)          SKIP_SOUL=true; shift ;;
    --skip-providers)     SKIP_PROVIDERS=true; shift ;;
    --non-interactive)    NON_INTERACTIVE=true; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: postinstall.sh [OPTIONS]

AI Providers (repeatable):
  --provider <choice>       Provider auth-choice (e.g. anthropic-api-key, ollama,
                            opencode-go, opencode-zen, gemini-api-key, openai-codex)
  --provider-key <key>      API key for the preceding --provider
                            (not needed for openai-codex — uses OAuth browser flow)
  --ollama-url <url>        Ollama/OpenWebUI base URL (default: http://localhost:11434)
  --custom-base-url <url>   Custom provider base URL

Embeddings:
  --openai-key <key>        OpenAI key (for memory embeddings only)

Model Roles:
  --primary-model <model>   Primary model (e.g. opencode-go/kimi-k2.5)
  --fallback-models <csv>   Comma-separated fallback models
  --heartbeat-model <model> Heartbeat/lightweight model

Telegram:
  --telegram-token <token>  Bot token from @BotFather
  --telegram-user-id <id>   Your numeric Telegram user ID

Tailscale:
  --tailscale-auth-key <key>  Auth key for non-interactive setup

Skips:
  --skip-providers          Skip AI provider setup
  --skip-tailscale          Skip Tailscale setup
  --skip-soul               Skip SOUL.md editor prompt
  --non-interactive         No prompts (use flags for all values)
USAGE
      exit 0 ;;
    *) msg_error "Unknown flag: $1"; exit 1 ;;
  esac
done

# -- Helpers -------------------------------------------------------------------
prompt_value() {
  local VARNAME="$1"
  local PROMPT_TEXT="$2"
  local DEFAULT="${3:-}"
  local SENSITIVE="${4:-false}"

  local CURRENT="${!VARNAME:-}"
  if [[ -n "$CURRENT" ]]; then return 0; fi

  if $NON_INTERACTIVE; then
    [[ -n "$DEFAULT" ]] && eval "$VARNAME='$DEFAULT'"
    return 0
  fi

  local DISPLAY_DEFAULT=""
  [[ -n "$DEFAULT" ]] && DISPLAY_DEFAULT=" [${DEFAULT}]"

  if [[ "$SENSITIVE" == "true" ]]; then
    printf "   ${BL}%s${CL}%s: " "$PROMPT_TEXT" "$DISPLAY_DEFAULT"
    read -rs REPLY
    if [[ -n "$REPLY" ]]; then
      echo -e " ${GN}[entered]${CL}"
    else
      echo ""
    fi
  else
    printf "   ${BL}%s${CL}%s: " "$PROMPT_TEXT" "$DISPLAY_DEFAULT"
    read -r REPLY
  fi

  if [[ -n "$REPLY" ]]; then
    eval "$VARNAME='$REPLY'"
  elif [[ -n "$DEFAULT" ]]; then
    eval "$VARNAME='$DEFAULT'"
  fi
}

prompt_yesno() {
  local PROMPT_TEXT="$1"
  local DEFAULT="${2:-y}"
  if $NON_INTERACTIVE; then [[ "$DEFAULT" == "y" ]]; return; fi

  local HINT="[Y/n]"; [[ "$DEFAULT" == "n" ]] && HINT="[y/N]"
  printf "   ${BL}%s${CL} %s: " "$PROMPT_TEXT" "$HINT"
  read -r REPLY
  REPLY="${REPLY:-$DEFAULT}"
  [[ "${REPLY,,}" == "y" || "${REPLY,,}" == "yes" ]]
}

# Register a single provider with openclaw onboard
register_provider() {
  local AUTH_CHOICE="$1"
  local API_KEY="${2:-}"
  local EXTRA_FLAGS="${3:-}"

  local CMD=(openclaw onboard --non-interactive --accept-risk --auth-choice "$AUTH_CHOICE" --skip-channels --skip-health --skip-skills --skip-ui)

  # Find the key flag for this auth-choice
  for entry in "${PROVIDER_REGISTRY[@]}"; do
    IFS='|' read -r _label _choice _keyflag _models <<< "$entry"
    if [[ "$_choice" == "$AUTH_CHOICE" && -n "$_keyflag" && -n "$API_KEY" ]]; then
      CMD+=($_keyflag "$API_KEY")
      break
    fi
  done

  # Append any extra flags (e.g., --custom-base-url)
  if [[ -n "$EXTRA_FLAGS" ]]; then
    # shellcheck disable=SC2206
    CMD+=($EXTRA_FLAGS)
  fi

  "${CMD[@]}" 2>&1 | tail -3 || true
}

# Approve all pending device pairing requests
_approve_pending_devices() {
  local PENDING_IDS
  PENDING_IDS=$(openclaw devices list 2>&1 | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' || true)
  if [[ -n "$PENDING_IDS" ]]; then
    for req_id in $PENDING_IDS; do
      openclaw devices approve "$req_id" >/dev/null 2>&1 || true
    done
    msg_ok "Device pairing request(s) approved"
  fi
}

# =============================================================================
# Preflight
# =============================================================================
echo ""
echo -e "${GN}============================================${CL}"
echo -e "${GN}  OpenClaw Post-Install Wizard${CL}"
echo -e "${GN}============================================${CL}"
echo ""

if ! command -v openclaw &>/dev/null; then
  msg_error "openclaw not found in PATH. Is OpenClaw installed?"
  msg_info "Expected at: ~/.npm-global/bin/openclaw"
  exit 1
fi
msg_ok "OpenClaw $(openclaw --version 2>&1 | head -1) detected"

if [[ ! -f "$OC_CONFIG" ]]; then
  msg_error "Config not found at $OC_CONFIG"
  msg_info "Run the install script first: bash ~/agentfarm/openclaw/install.sh"
  exit 1
fi
msg_ok "Config file found"

# =============================================================================
# Step 1: AI Providers
# =============================================================================
step_ai_providers() {
  msg_step "Step 1/6: AI Providers"

  if $SKIP_PROVIDERS; then
    msg_warn "Skipped (--skip-providers)"
    return 0
  fi

  # Show currently registered providers
  local REGISTERED=()
  if [[ -f "$AUTH_PROFILES" ]]; then
    while IFS= read -r p; do
      REGISTERED+=("$p")
    done < <(jq -r '.profiles | keys[]' "$AUTH_PROFILES" 2>/dev/null)
  fi

  if [[ ${#REGISTERED[@]} -gt 0 ]]; then
    msg_info "Currently registered providers:"
    for p in "${REGISTERED[@]}"; do
      msg_dim "  - $p"
    done
    echo ""
  fi

  # --- CLI flag mode: register providers passed via --provider / --provider-key
  if [[ ${#CLI_PROVIDERS[@]} -gt 0 ]]; then
    for i in "${!CLI_PROVIDERS[@]}"; do
      local choice="${CLI_PROVIDERS[$i]}"
      local key="${CLI_PROVIDER_KEYS[$i]:-}"
      local extra=""

      # Codex OAuth requires interactive mode — can't do it via flags
      if [[ "$choice" == "openai-codex" ]]; then
        msg_warn "openai-codex uses OAuth and requires interactive mode. Skipping."
        msg_info "Run interactively: bash ~/agentfarm/openclaw/postinstall.sh"
        continue
      fi

      [[ "$choice" == "ollama" && -n "$OLLAMA_BASE_URL" ]] && extra="--custom-base-url $OLLAMA_BASE_URL"
      [[ "$choice" == "custom-api-key" && -n "$CUSTOM_BASE_URL" ]] && extra="--custom-base-url $CUSTOM_BASE_URL"

      msg_info "Registering provider: ${choice}..."
      register_provider "$choice" "$key" "$extra"
      msg_ok "Registered: ${choice}"
    done
    return 0
  fi

  # --- Interactive mode: show menu
  if $NON_INTERACTIVE; then
    msg_warn "Non-interactive mode: use --provider/--provider-key flags to add providers"
    return 0
  fi

  echo ""
  msg_info "Select AI providers to configure (you can add multiple):"
  echo ""

  local DONE=false
  while ! $DONE; do
    # Print numbered menu
    for i in "${!PROVIDER_REGISTRY[@]}"; do
      IFS='|' read -r label _choice _keyflag models <<< "${PROVIDER_REGISTRY[$i]}"
      local NUM=$((i + 1))
      # Check if already registered
      local STATUS=" "
      for p in "${REGISTERED[@]}"; do
        if [[ "$p" == *"${_choice%%%-*}"* ]]; then
          STATUS="${GN}\xE2\x9C\x94${CL}"
          break
        fi
      done
      printf "   ${BL}%2d${CL}) %b %s  ${DM}%s${CL}\n" "$NUM" "$STATUS" "$label" "$models"
    done
    echo ""
    printf "   ${BL}Pick a number (or 'd' when done, 's' to skip)${CL}: "
    read -r CHOICE

    case "${CHOICE,,}" in
      d|done) DONE=true; continue ;;
      s|skip) msg_warn "Provider setup skipped"; return 0 ;;
      ''    ) continue ;;
    esac

    # Validate number
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [[ "$CHOICE" -lt 1 || "$CHOICE" -gt ${#PROVIDER_REGISTRY[@]} ]]; then
      msg_warn "Invalid selection"
      continue
    fi

    local IDX=$((CHOICE - 1))
    IFS='|' read -r LABEL AUTH_CHOICE KEY_FLAG EXAMPLE_MODELS <<< "${PROVIDER_REGISTRY[$IDX]}"

    echo ""
    msg_info "Setting up: ${LABEL}"
    msg_dim "Example models: ${EXAMPLE_MODELS}"

    local PROVIDER_KEY=""
    local EXTRA_FLAGS=""

    if [[ "$AUTH_CHOICE" == "openai-codex" ]]; then
      # Codex OAuth: browser-based flow, no API key
      echo ""
      msg_info "Codex uses OAuth — you'll authorize via your ChatGPT account."
      msg_info "This requires a ChatGPT Plus/Pro/Team subscription."
      msg_warn "Note: Codex OAuth tokens may need re-auth every ~10-30 days (known issue)."
      msg_warn "Embeddings are NOT included — set an OpenAI API key in Step 2 for memory."
      echo ""

      if $NON_INTERACTIVE; then
        msg_warn "OAuth requires interactive mode. Skipping Codex registration."
        msg_info "Run interactively later: bash ~/agentfarm/openclaw/postinstall.sh"
        echo ""
        continue
      fi

      if prompt_yesno "Start OAuth flow now? (opens a URL to paste in your browser)"; then
        msg_info "Running: openclaw onboard --auth-choice openai-codex"
        echo ""
        openclaw onboard --auth-choice openai-codex --skip-channels --skip-health --skip-skills --skip-ui 2>&1 || {
          msg_warn "OAuth flow failed or was cancelled."
          echo ""
          continue
        }
        msg_ok "Codex OAuth registered"
        REGISTERED+=("openai-codex:default")
      else
        msg_warn "Skipped. Run later: openclaw onboard --auth-choice openai-codex"
      fi
      echo ""
      continue

    elif [[ "$AUTH_CHOICE" == "ollama" ]]; then
      # Ollama: supports local installs or remote proxies (e.g. OpenWebUI)
      local OLLAMA_URL="http://localhost:11434"
      prompt_value OLLAMA_URL "Ollama base URL (or OpenWebUI/remote URL)" "http://localhost:11434"
      if [[ "$OLLAMA_URL" != "http://localhost:11434" ]]; then
        EXTRA_FLAGS="--custom-base-url $OLLAMA_URL"
      fi
      # Remote Ollama endpoints (OpenWebUI etc.) may require an API key
      local OLLAMA_KEY=""
      prompt_value OLLAMA_KEY "API key (blank if local/no auth needed)" "" "true"
      if [[ -n "$OLLAMA_KEY" ]]; then
        PROVIDER_KEY="$OLLAMA_KEY"
        # Ollama auth-choice doesn't have a key flag, register via custom instead
        AUTH_CHOICE="custom-api-key"
        EXTRA_FLAGS="--custom-base-url $OLLAMA_URL --custom-compatibility openai"
      fi
    elif [[ "$AUTH_CHOICE" == "custom-api-key" ]]; then
      # Custom: need base URL + optional key
      local CUST_URL=""
      prompt_value CUST_URL "Base URL (OpenAI-compatible endpoint)"
      prompt_value PROVIDER_KEY "API key (leave blank if none)" "" "true"
      [[ -n "$CUST_URL" ]] && EXTRA_FLAGS="--custom-base-url $CUST_URL --custom-compatibility openai"
    else
      # Standard provider: need API key
      prompt_value PROVIDER_KEY "API key" "" "true"
      if [[ -z "$PROVIDER_KEY" ]]; then
        msg_warn "No key provided, skipping ${LABEL}"
        echo ""
        continue
      fi
    fi

    msg_info "Registering ${LABEL}..."
    register_provider "$AUTH_CHOICE" "$PROVIDER_KEY" "$EXTRA_FLAGS"
    msg_ok "Registered: ${LABEL}"

    # Track it as registered for the checkmark display
    REGISTERED+=("${AUTH_CHOICE}:default")

    # Also write key to .env for providers that benefit from env-level access
    if [[ -n "$PROVIDER_KEY" ]]; then
      local ENV_VAR_NAME=""
      case "$AUTH_CHOICE" in
        anthropic-api-key)   ENV_VAR_NAME="ANTHROPIC_API_KEY" ;;
        openai-api-key)      ENV_VAR_NAME="OPENAI_API_KEY" ;;
        openrouter-api-key)  ENV_VAR_NAME="OPENROUTER_API_KEY" ;;
        gemini-api-key)      ENV_VAR_NAME="GEMINI_API_KEY" ;;
        opencode-zen)        ENV_VAR_NAME="OPENCODE_ZEN_API_KEY" ;;
        opencode-go)         ENV_VAR_NAME="OPENCODE_GO_API_KEY" ;;
        deepseek-api-key)    ENV_VAR_NAME="DEEPSEEK_API_KEY" ;;
        xai-api-key)         ENV_VAR_NAME="XAI_API_KEY" ;;
        mistral-api-key)     ENV_VAR_NAME="MISTRAL_API_KEY" ;;
        together-api-key)    ENV_VAR_NAME="TOGETHER_API_KEY" ;;
      esac
      if [[ -n "$ENV_VAR_NAME" ]]; then
        # Append/replace in .env
        touch "$OC_ENV"
        if grep -q "^${ENV_VAR_NAME}=" "$OC_ENV" 2>/dev/null; then
          sed -i "s|^${ENV_VAR_NAME}=.*|${ENV_VAR_NAME}=${PROVIDER_KEY}|" "$OC_ENV"
        else
          echo "${ENV_VAR_NAME}=${PROVIDER_KEY}" >> "$OC_ENV"
        fi
        chmod 600 "$OC_ENV"
      fi
    fi

    echo ""
  done
}

# =============================================================================
# Step 2: Embeddings Key (OpenAI for memory)
# =============================================================================
step_embeddings() {
  msg_step "Step 2/6: Memory Embeddings (OpenAI)"

  msg_dim "OpenClaw uses OpenAI's text-embedding-3-small for semantic memory search."
  msg_dim "This is separate from your AI model providers."

  local EXISTING_OPENAI=""
  if [[ -f "$OC_ENV" ]]; then
    EXISTING_OPENAI=$(grep -oP '^OPENAI_API_KEY=\K.*' "$OC_ENV" 2>/dev/null || true)
  fi
  [[ -z "$EXISTING_OPENAI" ]] && EXISTING_OPENAI="${OPENAI_API_KEY:-}"

  if [[ -n "$EXISTING_OPENAI" && -z "$OPENAI_KEY" ]]; then
    msg_ok "OpenAI API key already set in .env (memory search active)"
    return 0
  fi

  prompt_value OPENAI_KEY "OpenAI API key for embeddings" "" "true"

  if [[ -n "$OPENAI_KEY" ]]; then
    touch "$OC_ENV"
    if grep -q "^OPENAI_API_KEY=" "$OC_ENV" 2>/dev/null; then
      sed -i "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=${OPENAI_KEY}|" "$OC_ENV"
    else
      echo "OPENAI_API_KEY=${OPENAI_KEY}" >> "$OC_ENV"
    fi
    chmod 600 "$OC_ENV"
    msg_ok "OpenAI key written to .env (memory search enabled)"
  else
    msg_warn "No key provided. Semantic memory search will be disabled."
    msg_info "Set later: echo 'OPENAI_API_KEY=sk-...' >> ~/.openclaw/.env"
  fi
}

# =============================================================================
# Step 3: Model Roles
# =============================================================================
step_model_config() {
  msg_step "Step 3/6: Model Roles"

  # Read current config
  local CURRENT_PRIMARY CURRENT_FALLBACKS CURRENT_HEARTBEAT CURRENT_SUBAGENT CURRENT_CONCURRENCY CURRENT_SUB_CONCURRENCY
  CURRENT_PRIMARY=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "not set"' "$OC_CONFIG" 2>/dev/null)
  CURRENT_FALLBACKS=$(jq -r '(.agents.defaults.model.fallbacks // []) | join(", ")' "$OC_CONFIG" 2>/dev/null)
  CURRENT_HEARTBEAT=$(jq -r '.agents.defaults.heartbeat.model // "not set"' "$OC_CONFIG" 2>/dev/null)
  CURRENT_SUBAGENT=$(jq -r '.agents.defaults.subagents.model.primary // .agents.defaults.subagents.model // "not set"' "$OC_CONFIG" 2>/dev/null)
  CURRENT_CONCURRENCY=$(jq -r '.agents.defaults.maxConcurrent // "not set"' "$OC_CONFIG" 2>/dev/null)
  CURRENT_SUB_CONCURRENCY=$(jq -r '.agents.defaults.subagents.maxConcurrent // "not set"' "$OC_CONFIG" 2>/dev/null)

  msg_info "Current model roles:"
  msg_dim "  Primary (conversation): ${CURRENT_PRIMARY}"
  msg_dim "  Fallbacks:              ${CURRENT_FALLBACKS:-none}"
  msg_dim "  Sub-agents (tasks):     ${CURRENT_SUBAGENT}"
  msg_dim "  Heartbeat (background): ${CURRENT_HEARTBEAT}"
  msg_dim "  Concurrency:            ${CURRENT_CONCURRENCY} main / ${CURRENT_SUB_CONCURRENCY} sub-agents"
  echo ""

  # Non-interactive: apply flags if provided, otherwise keep current
  if $NON_INTERACTIVE && [[ -z "$PRIMARY_MODEL" && -z "$FALLBACK_MODELS" && -z "$HEARTBEAT_MODEL" ]]; then
    msg_info "No model overrides provided. Keeping current config."
    return 0
  fi

  # Interactive: offer a template or manual config
  if ! $NON_INTERACTIVE; then
    echo ""
    msg_info "How would you like to configure models?"
    echo ""
    printf "   ${BL} 1${CL}) OpenCode Go 4 Mains — tiered config using the 4 currently available models\n"
    printf "   ${BL} 2${CL}) OpenCode Go Future — full tiered config (MiMo-V2-Omni/Pro when available)\n"
    printf "   ${BL} 3${CL}) Manual — set each role individually\n"
    printf "   ${BL} s${CL}) Skip — keep current config\n"
    echo ""
    printf "   ${BL}Pick${CL}: "
    read -r MODE_CHOICE

    case "${MODE_CHOICE,,}" in
      s|skip)
        msg_ok "Model config unchanged"
        return 0 ;;
      1)
        _model_template_opencode_go_4mains
        return 0 ;;
      2)
        _model_template_opencode_go_future
        return 0 ;;
      3)
        _model_manual
        return 0 ;;
      *)
        msg_warn "Invalid choice, keeping current config"
        return 0 ;;
    esac
  fi

  # CLI flag path (non-interactive)
  _model_apply_flags
}

# -- OpenCode Go 4 Mains template ----------------------------------------------
# Uses only the 4 models currently available on OpenCode Go:
# Kimi K2.5, GLM-5, MiniMax M2.7, MiniMax M2.5
_model_template_opencode_go_4mains() {
  echo ""
  msg_info "OpenCode Go 4 Mains"
  msg_dim "Uses the 4 models currently available on OpenCode Go."
  msg_dim "Kimi K2.5 handles conversation (strongest reasoning)."
  msg_dim "MiniMax M2.7 handles sub-agents (highest usable quota)."
  msg_dim "MiniMax M2.5 handles heartbeat (cheapest)."
  msg_dim "GLM-5 available as secondary fallback."
  echo ""

  local G4_PRIMARY="" G4_FALLBACKS="" G4_SUBAGENT="" G4_HEARTBEAT=""

  msg_info "Primary model — handles direct conversation and reasoning."
  msg_dim "Default: opencode-go/kimi-k2.5 (~9,250 req/mo, strongest reasoning)"
  prompt_value G4_PRIMARY "Primary model" "${CURRENT_PRIMARY:-opencode-go/kimi-k2.5}"

  msg_info "Fallback models (comma-separated) — used when primary hits rate limits."
  msg_dim "Default: opencode-go/minimax-m2.7, opencode-go/glm-5"
  prompt_value G4_FALLBACKS "Fallback models" "${CURRENT_FALLBACKS:-opencode-go/minimax-m2.7, opencode-go/glm-5}"

  msg_info "Sub-agent model — delegated tasks (research, tool calls, grunt work)."
  msg_dim "Default: opencode-go/minimax-m2.7 (~70,000 req/mo — high headroom)"
  msg_dim "Uses a SEPARATE rate limit pool from primary to preserve conversation quota."
  prompt_value G4_SUBAGENT "Sub-agent model" "${CURRENT_SUBAGENT:-opencode-go/minimax-m2.7}"

  msg_info "Heartbeat model — background pings, cheapest possible."
  msg_dim "Default: opencode-go/minimax-m2.5 (~100,000 req/mo)"
  prompt_value G4_HEARTBEAT "Heartbeat model" "${CURRENT_HEARTBEAT:-opencode-go/minimax-m2.5}"

  # Apply: primary
  if [[ -n "$G4_PRIMARY" && "$G4_PRIMARY" != "$CURRENT_PRIMARY" ]]; then
    openclaw config set agents.defaults.model.primary "$G4_PRIMARY" >/dev/null 2>&1
    msg_ok "Primary: ${G4_PRIMARY}"
  else
    msg_ok "Primary unchanged: ${CURRENT_PRIMARY}"
  fi

  # Apply: fallbacks
  if [[ -n "$G4_FALLBACKS" && "$G4_FALLBACKS" != "$CURRENT_FALLBACKS" ]]; then
    local FB_JSON
    FB_JSON=$(echo "$G4_FALLBACKS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s .)
    jq --argjson fb "$FB_JSON" '.agents.defaults.model.fallbacks = $fb' "$OC_CONFIG" > "${OC_CONFIG}.tmp"
    mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
    msg_ok "Fallbacks: ${G4_FALLBACKS}"
  fi

  # Apply: sub-agents (separate model from primary)
  if [[ -n "$G4_SUBAGENT" && "$G4_SUBAGENT" != "$CURRENT_SUBAGENT" ]]; then
    jq --arg sa "$G4_SUBAGENT" \
      '.agents.defaults.subagents.model = {"primary": $sa, "fallbacks": ["opencode-go/minimax-m2.5"]}' \
      "$OC_CONFIG" > "${OC_CONFIG}.tmp"
    mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
    msg_ok "Sub-agents: ${G4_SUBAGENT} (separate pool from primary)"
  fi

  # Apply: heartbeat
  if [[ -n "$G4_HEARTBEAT" && "$G4_HEARTBEAT" != "$CURRENT_HEARTBEAT" ]]; then
    openclaw config set agents.defaults.heartbeat.model "$G4_HEARTBEAT" >/dev/null 2>&1
    msg_ok "Heartbeat: ${G4_HEARTBEAT}"
  else
    msg_ok "Heartbeat unchanged: ${CURRENT_HEARTBEAT}"
  fi

  # Apply: concurrency caps (subscription-safe)
  jq '.agents.defaults.maxConcurrent = 2 | .agents.defaults.subagents.maxConcurrent = 3' \
    "$OC_CONFIG" > "${OC_CONFIG}.tmp"
  mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
  msg_ok "Concurrency: 2 main / 3 sub-agents (subscription-safe)"

  echo ""
  msg_ok "OpenCode Go 4 Mains template applied"
}

# -- OpenCode Go Future template -----------------------------------------------
# Full tiered config for when MiMo-V2-Omni and MiMo-V2-Pro become available.
_model_template_opencode_go_future() {
  echo ""
  msg_info "OpenCode Go Future (MiMo-V2 models not yet available)"
  msg_dim "Full tiered architecture for when MiMo-V2-Omni and MiMo-V2-Pro launch."
  msg_dim "MiMo-V2-Omni handles conversation (multimodal); sub-agents use MiniMax M2.7"
  msg_dim "to preserve conversational quota. AGENTS.md instructs the agent to escalate"
  msg_dim "to MiMo-V2-Pro for complex tasks requiring 1M context."
  msg_warn "Note: MiMo-V2 models are not yet available. Use '4 Mains' for now."
  echo ""

  local OG_PRIMARY="" OG_FALLBACKS="" OG_SUBAGENT="" OG_HEARTBEAT=""

  msg_info "Primary model — handles direct conversation and reasoning."
  msg_dim "Default: opencode-go/MiMo-V2-Omni (multimodal, ~10,900 req/mo)"
  prompt_value OG_PRIMARY "Primary model" "${CURRENT_PRIMARY:-opencode-go/MiMo-V2-Omni}"

  msg_info "Fallback models (comma-separated) — used when primary hits rate limits."
  msg_dim "Default: opencode-go/kimi-k2.5, opencode-go/minimax-m2.7"
  prompt_value OG_FALLBACKS "Fallback models" "${CURRENT_FALLBACKS:-opencode-go/kimi-k2.5, opencode-go/minimax-m2.7}"

  msg_info "Sub-agent model — used for delegated tasks (research, tool calls, grunt work)."
  msg_dim "Default: opencode-go/minimax-m2.7 (~70,000 req/mo — high headroom)"
  msg_dim "Uses a SEPARATE rate limit pool from primary to preserve conversation quota."
  prompt_value OG_SUBAGENT "Sub-agent model" "${CURRENT_SUBAGENT:-opencode-go/minimax-m2.7}"

  msg_info "Heartbeat model — background pings, cheapest possible."
  msg_dim "Default: opencode-go/minimax-m2.5 (~100,000 req/mo)"
  prompt_value OG_HEARTBEAT "Heartbeat model" "${CURRENT_HEARTBEAT:-opencode-go/minimax-m2.5}"

  # Apply: primary
  if [[ -n "$OG_PRIMARY" && "$OG_PRIMARY" != "$CURRENT_PRIMARY" ]]; then
    openclaw config set agents.defaults.model.primary "$OG_PRIMARY" >/dev/null 2>&1
    msg_ok "Primary: ${OG_PRIMARY}"
  else
    msg_ok "Primary unchanged: ${CURRENT_PRIMARY}"
  fi

  # Apply: fallbacks
  if [[ -n "$OG_FALLBACKS" && "$OG_FALLBACKS" != "$CURRENT_FALLBACKS" ]]; then
    local FB_JSON
    FB_JSON=$(echo "$OG_FALLBACKS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s .)
    jq --argjson fb "$FB_JSON" '.agents.defaults.model.fallbacks = $fb' "$OC_CONFIG" > "${OC_CONFIG}.tmp"
    mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
    msg_ok "Fallbacks: ${OG_FALLBACKS}"
  fi

  # Apply: sub-agents (separate model from primary — key to rate limit strategy)
  if [[ -n "$OG_SUBAGENT" && "$OG_SUBAGENT" != "$CURRENT_SUBAGENT" ]]; then
    # Set sub-agent model with its own fallback chain
    jq --arg sa "$OG_SUBAGENT" \
      '.agents.defaults.subagents.model = {"primary": $sa, "fallbacks": ["opencode-go/minimax-m2.5"]}' \
      "$OC_CONFIG" > "${OC_CONFIG}.tmp"
    mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
    msg_ok "Sub-agents: ${OG_SUBAGENT} (separate pool from primary)"
  fi

  # Apply: heartbeat
  if [[ -n "$OG_HEARTBEAT" && "$OG_HEARTBEAT" != "$CURRENT_HEARTBEAT" ]]; then
    openclaw config set agents.defaults.heartbeat.model "$OG_HEARTBEAT" >/dev/null 2>&1
    msg_ok "Heartbeat: ${OG_HEARTBEAT}"
  else
    msg_ok "Heartbeat unchanged: ${CURRENT_HEARTBEAT}"
  fi

  # Apply: concurrency caps (subscription-safe)
  jq '.agents.defaults.maxConcurrent = 2 | .agents.defaults.subagents.maxConcurrent = 3' \
    "$OC_CONFIG" > "${OC_CONFIG}.tmp"
  mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
  msg_ok "Concurrency: 2 main / 3 sub-agents (subscription-safe)"

  echo ""
  msg_ok "OpenCode Go Future template applied"
}

# -- Manual per-role config ----------------------------------------------------
_model_manual() {
  echo ""
  msg_info "Configure each model role individually."
  msg_dim "Leave blank to keep current value. Format: provider/model-name"
  echo ""

  # Primary
  local M_PRIMARY=""
  msg_info "Primary — main conversation model."
  prompt_value M_PRIMARY "Primary model" "$CURRENT_PRIMARY"
  if [[ -n "$M_PRIMARY" && "$M_PRIMARY" != "$CURRENT_PRIMARY" ]]; then
    openclaw config set agents.defaults.model.primary "$M_PRIMARY" >/dev/null 2>&1
    msg_ok "Primary: ${M_PRIMARY}"
  else
    msg_ok "Primary unchanged: ${CURRENT_PRIMARY}"
  fi

  # Fallbacks
  local M_FALLBACKS=""
  msg_info "Fallbacks — backup models (comma-separated)."
  prompt_value M_FALLBACKS "Fallback models" "$CURRENT_FALLBACKS"
  if [[ -n "$M_FALLBACKS" && "$M_FALLBACKS" != "$CURRENT_FALLBACKS" ]]; then
    local FB_JSON
    FB_JSON=$(echo "$M_FALLBACKS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s .)
    jq --argjson fb "$FB_JSON" '.agents.defaults.model.fallbacks = $fb' "$OC_CONFIG" > "${OC_CONFIG}.tmp"
    mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
    msg_ok "Fallbacks: ${M_FALLBACKS}"
  fi

  # Sub-agents
  local M_SUBAGENT=""
  msg_info "Sub-agents — model for delegated tasks (research, tool calls, grunt work)."
  msg_dim "Use a high-quota model to avoid eating into primary's rate limit."
  msg_dim "Default: opencode-go/minimax-m2.7 (~70k req/mo)"
  prompt_value M_SUBAGENT "Sub-agent model" "$CURRENT_SUBAGENT"
  if [[ -n "$M_SUBAGENT" && "$M_SUBAGENT" != "$CURRENT_SUBAGENT" ]]; then
    jq --arg sa "$M_SUBAGENT" \
      '.agents.defaults.subagents.model = {"primary": $sa, "fallbacks": ["opencode-go/minimax-m2.5"]}' \
      "$OC_CONFIG" > "${OC_CONFIG}.tmp"
    mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
    msg_ok "Sub-agents: ${M_SUBAGENT}"
  fi

  # Heartbeat
  local M_HEARTBEAT=""
  msg_info "Heartbeat — cheap/fast model for background monitoring."
  prompt_value M_HEARTBEAT "Heartbeat model" "$CURRENT_HEARTBEAT"
  if [[ -n "$M_HEARTBEAT" && "$M_HEARTBEAT" != "$CURRENT_HEARTBEAT" ]]; then
    openclaw config set agents.defaults.heartbeat.model "$M_HEARTBEAT" >/dev/null 2>&1
    msg_ok "Heartbeat: ${M_HEARTBEAT}"
  fi

  echo ""
  msg_ok "Manual model config applied"
}

# -- Apply CLI flags (non-interactive) -----------------------------------------
_model_apply_flags() {
  if [[ -n "$PRIMARY_MODEL" ]]; then
    openclaw config set agents.defaults.model.primary "$PRIMARY_MODEL" >/dev/null 2>&1
    msg_ok "Primary model: ${PRIMARY_MODEL}"
  fi

  if [[ -n "$FALLBACK_MODELS" ]]; then
    local FB_JSON
    FB_JSON=$(echo "$FALLBACK_MODELS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s .)
    jq --argjson fb "$FB_JSON" '.agents.defaults.model.fallbacks = $fb' "$OC_CONFIG" > "${OC_CONFIG}.tmp"
    mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
    msg_ok "Fallback models: ${FALLBACK_MODELS}"
  fi

  if [[ -n "$HEARTBEAT_MODEL" ]]; then
    openclaw config set agents.defaults.heartbeat.model "$HEARTBEAT_MODEL" >/dev/null 2>&1
    msg_ok "Heartbeat model: ${HEARTBEAT_MODEL}"
  fi
}

# =============================================================================
# Step 4: Telegram Bot
# =============================================================================
step_telegram() {
  msg_step "Step 4/6: Telegram"

  local CURRENT_TOKEN
  CURRENT_TOKEN=$(jq -r '.channels.telegram.botToken // ""' "$OC_CONFIG" 2>/dev/null)

  if [[ "$CURRENT_TOKEN" == "__TELEGRAM_BOT_TOKEN__" || -z "$CURRENT_TOKEN" ]]; then
    msg_warn "Telegram bot token is not configured"

    if [[ -z "$TELEGRAM_TOKEN" ]] && ! $NON_INTERACTIVE; then
      echo ""
      msg_info "To get a bot token:"
      msg_info "  1. Open Telegram and message @BotFather"
      msg_info "  2. Send /newbot and follow the prompts"
      msg_info "  3. Copy the token (format: 123456789:ABCdef...)"
      echo ""
      prompt_value TELEGRAM_TOKEN "Telegram bot token" "" "true"
    fi

    if [[ -n "$TELEGRAM_TOKEN" ]]; then
      openclaw config set channels.telegram.botToken "$TELEGRAM_TOKEN" >/dev/null 2>&1
      msg_ok "Telegram bot token configured"
    else
      msg_warn "No token provided. Telegram will not work."
      msg_info "  Set later: openclaw config set channels.telegram.botToken YOUR_TOKEN"
    fi
  else
    msg_ok "Telegram bot token already configured"
  fi

  # Telegram user ID (DM allowlist)
  local CURRENT_ALLOW
  CURRENT_ALLOW=$(jq -r '.channels.telegram.allowFrom // [] | length' "$OC_CONFIG" 2>/dev/null)

  if [[ "$CURRENT_ALLOW" -eq 0 ]]; then
    msg_warn "No Telegram users in allowFrom (nobody can DM the bot)"

    if [[ -z "$TELEGRAM_USER_ID" ]] && ! $NON_INTERACTIVE; then
      echo ""
      msg_info "To find your Telegram user ID:"
      msg_info "  1. Message @userinfobot on Telegram"
      msg_info "  2. It will reply with your numeric ID"
      echo ""
      prompt_value TELEGRAM_USER_ID "Your Telegram user ID (numeric)"
    fi

    if [[ -n "$TELEGRAM_USER_ID" ]]; then
      local TMP_CONFIG
      TMP_CONFIG=$(jq --arg uid "$TELEGRAM_USER_ID" \
        '.channels.telegram.allowFrom = (.channels.telegram.allowFrom // []) + [$uid] | .channels.telegram.allowFrom |= unique' \
        "$OC_CONFIG")
      echo "$TMP_CONFIG" > "$OC_CONFIG"
      chmod 600 "$OC_CONFIG"
      msg_ok "Telegram user ${TELEGRAM_USER_ID} added to allowFrom"
    else
      msg_warn "No user ID provided. Configure DM access later."
    fi
  else
    msg_ok "Telegram allowFrom has ${CURRENT_ALLOW} user(s)"
  fi
}

# =============================================================================
# Step 5: Tailscale
# =============================================================================
# -- Tailscale browser auth with timeout and retry -----------------------------
_tailscale_browser_auth() {
  local MAX_WAIT=120  # seconds
  local AUTH_URL=""

  msg_info "Starting Tailscale browser login..."
  msg_dim "A URL will appear below. Open it in any browser to authenticate."
  msg_dim "You have ${MAX_WAIT} seconds before it times out."
  echo ""

  # Run tailscale up in the background, capture its output for the URL
  local TS_LOG
  TS_LOG=$(mktemp)
  sudo tailscale up 2>&1 | tee "$TS_LOG" &
  local TS_PID=$!

  # Wait for auth to complete or timeout
  local ELAPSED=0
  while kill -0 "$TS_PID" 2>/dev/null; do
    sleep 3
    ELAPSED=$((ELAPSED + 3))

    # Check if tailscale is now connected (auth succeeded)
    local CHECK_STATE
    CHECK_STATE=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"' 2>/dev/null || echo "Unknown")
    if [[ "$CHECK_STATE" == "Running" ]]; then
      # Auth succeeded — clean up background process
      wait "$TS_PID" 2>/dev/null || true
      rm -f "$TS_LOG"
      echo ""
      msg_ok "Tailscale authenticated"
      return 0
    fi

    if [[ $ELAPSED -ge $MAX_WAIT ]]; then
      # Timeout — kill the background process
      sudo kill "$TS_PID" 2>/dev/null || true
      wait "$TS_PID" 2>/dev/null || true
      rm -f "$TS_LOG"
      echo ""
      msg_warn "Tailscale auth timed out after ${MAX_WAIT} seconds."
      echo ""
      printf "   ${BL} r${CL}) Retry browser login\n"
      printf "   ${BL} k${CL}) Switch to auth key instead\n"
      printf "   ${BL} s${CL}) Skip — set up Tailscale later\n"
      echo ""
      printf "   ${BL}Pick${CL}: "
      read -r RETRY_CHOICE

      case "${RETRY_CHOICE,,}" in
        r|retry)
          _tailscale_browser_auth
          return $?
          ;;
        k|key)
          echo ""
          msg_info "Generate a key at: https://login.tailscale.com/admin/settings/keys"
          local TS_KEY_RETRY=""
          prompt_value TS_KEY_RETRY "Tailscale auth key" "" "true"
          if [[ -n "$TS_KEY_RETRY" ]]; then
            msg_info "Authenticating..."
            sudo tailscale up --auth-key="$TS_KEY_RETRY" 2>&1 || {
              msg_error "Auth key rejected. Try: sudo tailscale up"
              return 0
            }
            msg_ok "Tailscale authenticated"
          else
            msg_warn "No key provided. Skipping."
          fi
          return 0
          ;;
        *)
          msg_warn "Skipped. Run later: sudo tailscale up"
          return 0
          ;;
      esac
    fi
  done

  # tailscale up exited on its own — check result
  wait "$TS_PID" 2>/dev/null
  local EXIT_CODE=$?
  rm -f "$TS_LOG"

  if [[ $EXIT_CODE -eq 0 ]]; then
    local FINAL_STATE
    FINAL_STATE=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"' 2>/dev/null || echo "Unknown")
    if [[ "$FINAL_STATE" == "Running" ]]; then
      msg_ok "Tailscale authenticated"
    else
      msg_warn "Tailscale exited but state is '${FINAL_STATE}'. Check: sudo tailscale status"
    fi
  else
    msg_error "Tailscale auth failed (exit code ${EXIT_CODE})."
    echo ""
    printf "   ${BL} r${CL}) Retry browser login\n"
    printf "   ${BL} k${CL}) Switch to auth key instead\n"
    printf "   ${BL} s${CL}) Skip — set up Tailscale later\n"
    echo ""
    printf "   ${BL}Pick${CL}: "
    read -r FAIL_CHOICE

    case "${FAIL_CHOICE,,}" in
      r|retry)
        _tailscale_browser_auth
        return $?
        ;;
      k|key)
        echo ""
        msg_info "Generate a key at: https://login.tailscale.com/admin/settings/keys"
        local TS_KEY_FAIL=""
        prompt_value TS_KEY_FAIL "Tailscale auth key" "" "true"
        if [[ -n "$TS_KEY_FAIL" ]]; then
          msg_info "Authenticating..."
          sudo tailscale up --auth-key="$TS_KEY_FAIL" 2>&1 || {
            msg_error "Auth key rejected. Try: sudo tailscale up"
            return 0
          }
          msg_ok "Tailscale authenticated"
        fi
        ;;
      *)
        msg_warn "Skipped. Run later: sudo tailscale up"
        ;;
    esac
  fi
}

step_tailscale() {
  msg_step "Step 5/6: Tailscale"

  if $SKIP_TAILSCALE; then
    msg_warn "Skipped (--skip-tailscale)"
    return 0
  fi

  if ! command -v tailscale &>/dev/null; then
    msg_warn "Tailscale not installed. Skipping."
    return 0
  fi

  local TS_STATUS
  TS_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"' 2>/dev/null || echo "Unknown")

  if [[ "$TS_STATUS" == "Running" ]]; then
    local TS_IP
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
    msg_ok "Tailscale already connected (${TS_IP})"
  else
    msg_warn "Tailscale not connected (state: ${TS_STATUS})"

    # --- Non-interactive: use auth key or skip ---
    if $NON_INTERACTIVE; then
      if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        msg_info "Authenticating with provided auth key..."
        sudo tailscale up --auth-key="$TAILSCALE_AUTH_KEY" 2>&1 || {
          msg_error "Tailscale auth failed. Try: sudo tailscale up"
          return 0
        }
        msg_ok "Tailscale authenticated"
      else
        msg_warn "Non-interactive: provide --tailscale-auth-key to authenticate"
        return 0
      fi

    # --- CLI flag: auth key was passed ---
    elif [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
      msg_info "Authenticating with provided auth key..."
      sudo tailscale up --auth-key="$TAILSCALE_AUTH_KEY" 2>&1 || {
        msg_error "Tailscale auth failed. Try: sudo tailscale up"
        return 0
      }
      msg_ok "Tailscale authenticated"

    # --- Interactive: show options ---
    else
      echo ""
      msg_info "How would you like to connect Tailscale?"
      echo ""
      printf "   ${BL} 1${CL}) Browser login — generates a URL to open on any device\n"
      printf "   ${BL} 2${CL}) Auth key — paste a pre-generated key from the Tailscale admin console\n"
      printf "   ${BL} s${CL}) Skip — set up Tailscale later\n"
      echo ""
      printf "   ${BL}Pick${CL}: "
      read -r TS_CHOICE

      case "${TS_CHOICE,,}" in
        1)
          _tailscale_browser_auth
          ;;
        2)
          echo ""
          msg_info "Generate a key at: https://login.tailscale.com/admin/settings/keys"
          msg_dim "Use a reusable or single-use auth key."
          local TS_KEY_INPUT=""
          prompt_value TS_KEY_INPUT "Tailscale auth key" "" "true"
          if [[ -n "$TS_KEY_INPUT" ]]; then
            msg_info "Authenticating..."
            sudo tailscale up --auth-key="$TS_KEY_INPUT" 2>&1 || {
              msg_error "Auth key rejected. Try: sudo tailscale up"
              return 0
            }
            msg_ok "Tailscale authenticated"
          else
            msg_warn "No key provided. Skipping."
            return 0
          fi
          ;;
        s|skip|*)
          msg_warn "Skipped. Run later: sudo tailscale up"
          return 0
          ;;
      esac
    fi
  fi

  # Tailscale Serve
  local TS_SERVE_STATUS
  TS_SERVE_STATUS=$(sudo tailscale serve status 2>&1 || true)

  if echo "$TS_SERVE_STATUS" | grep -q "18789"; then
    msg_ok "Tailscale Serve already forwarding port 18789"
  else
    msg_info "Enabling Tailscale Serve for gateway (port 18789)..."
    sudo tailscale serve --bg 18789 2>&1 || {
      msg_warn "Failed. Run manually: sudo tailscale serve --bg 18789"
      return 0
    }
    msg_ok "Tailscale Serve enabled"
  fi

  # Sync OpenClaw gateway config to match Tailscale state
  local CURRENT_TS_MODE
  CURRENT_TS_MODE=$(jq -r '.gateway.tailscale.mode // "off"' "$OC_CONFIG" 2>/dev/null)
  if [[ "$CURRENT_TS_MODE" != "serve" ]]; then
    msg_info "Updating gateway config for Tailscale Serve..."
    openclaw config set gateway.tailscale.mode serve >/dev/null 2>&1
    openclaw config set gateway.tailscale.resetOnExit true --strict-json >/dev/null 2>&1
    msg_ok "Gateway Tailscale mode set to 'serve'"
  fi

  # Ensure exec tool runs through the gateway (not sandbox) so it can reach the network
  local CURRENT_EXEC_HOST
  CURRENT_EXEC_HOST=$(jq -r '.tools.exec.host // "auto"' "$OC_CONFIG" 2>/dev/null)
  if [[ "$CURRENT_EXEC_HOST" != "gateway" ]]; then
    openclaw config set tools.exec.host gateway >/dev/null 2>&1
    openclaw config set tools.exec.security full >/dev/null 2>&1
    msg_ok "Exec tool configured to run on gateway (full access)"
  fi

  # Add the Tailscale hostname to controlUi.allowedOrigins if not already there
  local TS_HOSTNAME
  TS_HOSTNAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
  if [[ -n "$TS_HOSTNAME" ]]; then
    local ORIGIN="https://${TS_HOSTNAME}"
    local HAS_ORIGIN
    HAS_ORIGIN=$(jq --arg o "$ORIGIN" '.gateway.controlUi.allowedOrigins // [] | map(select(. == $o)) | length' "$OC_CONFIG" 2>/dev/null)
    if [[ "$HAS_ORIGIN" == "0" ]]; then
      jq --arg o "$ORIGIN" '.gateway.controlUi.allowedOrigins = ((.gateway.controlUi.allowedOrigins // []) + [$o] | unique)' "$OC_CONFIG" > "${OC_CONFIG}.tmp"
      mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
      msg_ok "Added ${ORIGIN} to Control UI allowed origins"
    fi
  fi
}

# =============================================================================
# Step 6: Finalize
# =============================================================================
step_finalize() {
  msg_step "Step 6/6: Finalize"

  # NOTE: SOUL.md is NOT edited here. The hatching process (BOOTSTRAP.md + TUI)
  # generates SOUL.md interactively. Editing it before hatch would bypass the
  # personality creation experience.

  # Fix streamMode → streaming (doctor renames it but config can revert)
  if jq -e '.channels.telegram.streamMode' "$OC_CONFIG" >/dev/null 2>&1; then
    local SM_VAL
    SM_VAL=$(jq -r '.channels.telegram.streamMode' "$OC_CONFIG")
    jq "del(.channels.telegram.streamMode) | .channels.telegram.streaming = \"${SM_VAL}\"" "$OC_CONFIG" > "${OC_CONFIG}.tmp"
    mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
    msg_ok "Fixed streamMode → streaming"
  fi

  # Set gateway.remote.url if Tailscale is connected (so openclaw knows its external URL)
  if command -v tailscale &>/dev/null; then
    local TS_DNS
    TS_DNS=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
    if [[ -n "$TS_DNS" ]]; then
      local CURRENT_REMOTE_URL
      CURRENT_REMOTE_URL=$(jq -r '.gateway.remote.url // ""' "$OC_CONFIG" 2>/dev/null)
      if [[ "$CURRENT_REMOTE_URL" != "wss://${TS_DNS}" ]]; then
        openclaw config set gateway.remote.url "wss://${TS_DNS}" >/dev/null 2>&1
        msg_ok "Gateway remote URL: wss://${TS_DNS}"
      fi
    fi
  fi

  # Restart gateway
  msg_info "Restarting gateway..."
  systemctl --user restart openclaw-gateway.service 2>/dev/null || {
    msg_warn "Gateway restart failed. Try: systemctl --user restart openclaw-gateway.service"
  }
  sleep 3

  local GW_STATUS
  GW_STATUS=$(systemctl --user is-active openclaw-gateway.service 2>/dev/null || echo "unknown")
  if [[ "$GW_STATUS" == "active" ]]; then
    msg_ok "Gateway running"
  else
    msg_warn "Gateway status: ${GW_STATUS}"
  fi

  # Auto-approve any pre-existing pending device pairing requests
  _approve_pending_devices

  # Interactive browser pairing (if Tailscale is up and we're not in non-interactive mode)
  if ! $NON_INTERACTIVE && command -v tailscale &>/dev/null; then
    local TS_DNS_PAIR
    TS_DNS_PAIR=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
    if [[ -n "$TS_DNS_PAIR" ]]; then
      local GW_TOKEN_PAIR
      GW_TOKEN_PAIR=$(jq -r '.gateway.auth.token // ""' "$OC_CONFIG" 2>/dev/null)
      local DASH_URL="https://${TS_DNS_PAIR}/#token=${GW_TOKEN_PAIR}"

      echo ""
      echo -e "   ${GN}========================================${CL}"
      echo -e "   ${GN}  Browser Pairing${CL}"
      echo -e "   ${GN}========================================${CL}"
      echo ""
      msg_info "Open this URL in your browser now:"
      echo ""
      echo -e "   ${BL}${DASH_URL}${CL}"
      echo ""
      msg_info "The page will show 'pairing required' — that's expected."
      msg_info "Once you've loaded the page, come back here and press Enter."
      echo ""
      printf "   ${BL}Press Enter after opening the URL in your browser (or 's' to skip)${CL}: "
      read -r PAIR_REPLY

      if [[ "${PAIR_REPLY,,}" != "s" ]]; then
        # Give the browser a moment to send the pairing request
        sleep 2
        _approve_pending_devices

        # Check if it worked
        local PAIRED_NOW
        PAIRED_NOW=$(openclaw devices list 2>&1 | grep -c "Paired" || echo 0)
        if [[ "$PAIRED_NOW" -gt 0 ]]; then
          msg_ok "Browser paired! Refresh the page — you should be connected."
        else
          msg_warn "No pairing request detected. Try refreshing the browser, then run:"
          msg_info "  openclaw devices list"
          msg_info "  openclaw devices approve <request-id>"
        fi
      else
        msg_info "Skipped. Pair later by opening the URL and running:"
        msg_info "  openclaw devices list && openclaw devices approve <request-id>"
      fi
    fi
  fi

  # Enable internal hooks (config JSON alone is not sufficient — must use CLI)
  msg_info "Enabling internal hooks..."
  openclaw hooks enable boot-md 2>/dev/null || true
  openclaw hooks enable bootstrap-extra-files 2>/dev/null || true
  openclaw hooks enable command-logger 2>/dev/null || true
  openclaw hooks enable session-memory 2>/dev/null || true
  msg_ok "Hooks enabled (boot-md, bootstrap-extra-files, command-logger, session-memory)"

  # Doctor
  msg_info "Running openclaw doctor --fix..."
  openclaw doctor --fix 2>&1 | tail -5 || true
  msg_ok "Doctor completed"

  # Git commit
  if [[ -d "${OC_DIR}/.git" ]]; then
    cd "$OC_DIR"
    git add -A 2>/dev/null || true
    git commit -q -m "config: post-install wizard $(date +%Y-%m-%d)" 2>/dev/null || true
    msg_ok "Config committed to git"
  fi
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
  echo ""
  echo -e "${GN}============================================${CL}"
  echo -e "${GN}  Post-Install Complete${CL}"
  echo -e "${GN}============================================${CL}"
  echo ""

  local ISSUES=()

  # Providers
  local PROVIDER_COUNT=0
  if [[ -f "$AUTH_PROFILES" ]]; then
    PROVIDER_COUNT=$(jq '.profiles | length' "$AUTH_PROFILES" 2>/dev/null || echo 0)
  fi
  if [[ "$PROVIDER_COUNT" -gt 0 ]]; then
    msg_ok "${PROVIDER_COUNT} AI provider(s) registered"
  else
    ISSUES+=("Add an AI provider: re-run this wizard or openclaw configure --section model")
  fi

  # Model config
  local PM
  PM=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "not set"' "$OC_CONFIG" 2>/dev/null)
  msg_ok "Primary model: ${PM}"

  # Embeddings
  if [[ -f "$OC_ENV" ]] && grep -q "^OPENAI_API_KEY=" "$OC_ENV" 2>/dev/null; then
    msg_ok "Memory embeddings: configured"
  else
    ISSUES+=("Set OPENAI_API_KEY in ~/.openclaw/.env (for memory/embeddings)")
  fi

  # Telegram
  local TG_TOKEN
  TG_TOKEN=$(jq -r '.channels.telegram.botToken // ""' "$OC_CONFIG" 2>/dev/null)
  if [[ -n "$TG_TOKEN" && "$TG_TOKEN" != "__TELEGRAM_BOT_TOKEN__" ]]; then
    msg_ok "Telegram: configured"
  else
    ISSUES+=("Configure Telegram: openclaw config set channels.telegram.botToken TOKEN")
  fi

  # Tailscale + Dashboard URL
  if tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null 2>&1; then
    local TS_HOSTNAME_SUM
    TS_HOSTNAME_SUM=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
    msg_ok "Tailscale: connected ($(tailscale ip -4 2>/dev/null))"

    if [[ -n "$TS_HOSTNAME_SUM" ]]; then
      local GW_TOKEN_SUM
      GW_TOKEN_SUM=$(jq -r '.gateway.auth.token // ""' "$OC_CONFIG" 2>/dev/null)
      echo ""
      echo -e "   ${GN}Dashboard URL (bookmark this):${CL}"
      echo -e "   ${BL}https://${TS_HOSTNAME_SUM}/#token=${GW_TOKEN_SUM}${CL}"
      echo ""
      msg_dim "New browsers need device pairing: openclaw devices list && openclaw devices approve <id>"
      echo ""
    fi
  else
    ISSUES+=("Connect Tailscale: sudo tailscale up")
  fi

  # Gateway
  if systemctl --user is-active openclaw-gateway.service >/dev/null 2>&1; then
    msg_ok "Gateway: running"
  else
    ISSUES+=("Start gateway: openclaw gateway start")
  fi

  if [[ ${#ISSUES[@]} -gt 0 ]]; then
    echo ""
    msg_warn "Still needs attention:"
    for issue in "${ISSUES[@]}"; do
      echo -e "   ${YW}\xe2\x80\xa2${CL} ${issue}"
    done
  fi

  echo ""
}

# =============================================================================
# Install Memory Plugin (after hatching, so workspace is clean for bootstrap)
# =============================================================================
install_memory_plugin() {
  msg_info "Installing memory-lancedb-hybrid plugin..."
  (
    export PATH="${HOME}/.npm-global/bin:${PATH}"
    cd ~/.openclaw/workspace && \
    mkdir -p skills && \
    cd skills && \
    git clone https://github.com/CortexReach/memory-lancedb-pro.git memory-lancedb-hybrid 2>/dev/null && \
    cd memory-lancedb-hybrid && \
    npm install --omit=dev 2>&1 | tail -3
  ) || {
    msg_warn "Memory plugin install failed. Install manually later:"
    msg_warn "  cd ~/.openclaw/workspace/skills && git clone https://github.com/CortexReach/memory-lancedb-pro.git memory-lancedb-hybrid && cd memory-lancedb-hybrid && npm install --omit=dev"
    return 0
  }
  msg_ok "Memory plugin installed"
}

# =============================================================================
# Seed BOOTSTRAP.md from the OpenClaw shipped template
# =============================================================================
# The hatching process requires two things:
#   1. BOOTSTRAP.md exists in workspace (agent gets the hatching persona/instructions)
#   2. TUI launched with --message "Wake up, my friend!" (first message to kick it off)
#
# We do NOT use `openclaw onboard` for hatching. Onboard overwrites config,
# recreates workspace dirs, and trips the hasUserContent check that prevents
# BOOTSTRAP.md from ever being auto-seeded. Instead, we copy the shipped
# template directly and launch TUI ourselves.
#
# The agent will follow BOOTSTRAP.md's instructions to build SOUL.md,
# IDENTITY.md, and USER.md interactively, then delete BOOTSTRAP.md when done.
BOOTSTRAP_TEMPLATE="${HOME}/.npm-global/lib/node_modules/openclaw/docs/reference/templates/BOOTSTRAP.md"

seed_bootstrap() {
  local WS_DIR="${HOME}/.openclaw/workspace"
  local DEST="${WS_DIR}/BOOTSTRAP.md"

  if [[ -f "$DEST" ]]; then
    msg_dim "BOOTSTRAP.md already exists — skipping seed"
    return 0
  fi

  if [[ ! -f "$BOOTSTRAP_TEMPLATE" ]]; then
    msg_warn "BOOTSTRAP.md template not found at ${BOOTSTRAP_TEMPLATE}"
    msg_warn "OpenClaw may have moved it. Check: find ~/.npm-global -name BOOTSTRAP.md"
    return 1
  fi

  # Copy and strip YAML frontmatter (template has --- blocks that aren't needed at runtime)
  cp "$BOOTSTRAP_TEMPLATE" "$DEST"
  sed -i '1{/^---$/,/^---$/d}' "$DEST"
  chmod 644 "$DEST"
  msg_ok "BOOTSTRAP.md seeded from OpenClaw template"
}

# =============================================================================
# Hatch model selection + swap
# =============================================================================
# The hatching process needs a model with strong instruction-following to
# properly execute the BOOTSTRAP.md personality-building dialogue. Some models
# (e.g. Kimi K2.5) can't handle the tool-calling init flow, and lightweight
# models (e.g. gpt-4o-mini) ignore the bootstrap instructions entirely.
#
# SAVED_PRIMARY is intentionally global — set by swap_model_for_hatch(),
# consumed by restore_model_after_hatch().
SAVED_PRIMARY=""
HATCH_MODEL=""

# Interactive menu to choose the hatching model
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
  # Save current primary model (global — used by restore_model_after_hatch)
  SAVED_PRIMARY=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // ""' "$OC_CONFIG" 2>/dev/null)

  if [[ -z "$SAVED_PRIMARY" || "$SAVED_PRIMARY" == "null" ]]; then
    msg_warn "No primary model set — skipping model swap"
    return 0
  fi

  # No swap needed if already using the hatch model
  if [[ "$SAVED_PRIMARY" == "$HATCH_MODEL" ]]; then
    msg_dim "Primary model is already ${HATCH_MODEL} — no swap needed"
    SAVED_PRIMARY=""
    return 0
  fi

  msg_info "Temporarily setting primary model to ${HATCH_MODEL} for hatching..."
  msg_dim "(Original: ${SAVED_PRIMARY} — will be restored after hatch)"

  jq --arg m "$HATCH_MODEL" '.agents.defaults.model.primary = $m' "$OC_CONFIG" > "${OC_CONFIG}.tmp"
  mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"

  # Restart gateway so it picks up the new model
  systemctl --user restart openclaw-gateway.service 2>/dev/null || true
  sleep 2
}

restore_model_after_hatch() {
  if [[ -z "${SAVED_PRIMARY:-}" ]]; then
    return 0
  fi

  msg_info "Restoring primary model to ${SAVED_PRIMARY}..."
  jq --arg m "$SAVED_PRIMARY" '.agents.defaults.model.primary = $m' "$OC_CONFIG" > "${OC_CONFIG}.tmp"
  mv "${OC_CONFIG}.tmp" "$OC_CONFIG"; chmod 600 "$OC_CONFIG"
  msg_ok "Primary model restored: ${SAVED_PRIMARY}"

  # Restart gateway with the production model
  systemctl --user restart openclaw-gateway.service 2>/dev/null || true
  sleep 2
}

# =============================================================================
# Hatch the bot: BOOTSTRAP.md + TUI (no onboard wizard)
# =============================================================================
step_launch() {
  if $NON_INTERACTIVE; then
    return 0
  fi

  echo ""
  msg_info "Setup complete. Ready to hatch the bot."
  echo ""
  echo -e "   ${GN}========================================${CL}"
  echo -e "   ${GN}  Hatching${CL}"
  echo -e "   ${GN}========================================${CL}"
  echo ""
  msg_dim "The hatching process seeds BOOTSTRAP.md into the workspace and launches"
  msg_dim "the TUI with the first message: 'Wake up, my friend...'"
  msg_dim ""
  msg_dim "The bot will walk you through building its personality: name, vibe,"
  msg_dim "SOUL.md, IDENTITY.md, and USER.md. When done, it deletes BOOTSTRAP.md."
  msg_dim ""
  msg_dim "After you exit the TUI, the script restores your production model"
  msg_dim "and installs the memory plugin."
  msg_dim ""
  msg_warn "Do NOT message the bot on Telegram until hatching is complete."
  echo ""

  if prompt_yesno "Hatch the bot now?"; then

    # 1. Pick hatch model (interactive menu)
    pick_hatch_model

    # 2. Seed BOOTSTRAP.md
    echo ""
    seed_bootstrap || {
      msg_error "Cannot hatch without BOOTSTRAP.md. Fix the template path and re-run."
      return 1
    }

    # 3. Swap model
    swap_model_for_hatch

    # 4. Launch TUI with the hatching message
    echo ""
    msg_ok "Launching TUI — hatching begins..."
    echo ""
    openclaw tui --message "Wake up, my friend!"
    local TUI_EXIT=$?
    echo ""

    # 5. Post-hatch: restore original model
    restore_model_after_hatch

    # 6. Post-hatch: install memory plugin
    if [[ ! -d "${HOME}/.openclaw/workspace/skills/memory-lancedb-hybrid" ]]; then
      install_memory_plugin
    else
      msg_dim "Memory plugin already installed"
    fi

    # 7. Git commit post-hatch state
    if [[ -d "${OC_DIR}/.git" ]]; then
      cd "$OC_DIR"
      git add -A 2>/dev/null || true
      git commit -q -m "post-hatch: personality created, model restored, memory plugin $(date +%Y-%m-%d)" 2>/dev/null || true
      msg_ok "Post-hatch state committed to git"
    fi

    if [[ $TUI_EXIT -eq 0 ]]; then
      msg_ok "Hatching complete!"
    else
      msg_warn "TUI exited with code ${TUI_EXIT}."
    fi
  else
    echo ""
    msg_info "When ready, hatch manually:"
    echo ""
    echo -e "  ${DM}# 1. Seed the bootstrap file:${CL}"
    echo -e "  ${BL}cp ${BOOTSTRAP_TEMPLATE} ~/.openclaw/workspace/BOOTSTRAP.md${CL}"
    echo ""
    echo -e "  ${DM}# 2. Temporarily swap model (pick one with good instruction following):${CL}"
    echo -e "  ${BL}openclaw config set agents.defaults.model.primary opencode-go/glm-5${CL}"
    echo -e "  ${BL}systemctl --user restart openclaw-gateway.service${CL}"
    echo ""
    echo -e "  ${DM}# 3. Launch TUI:${CL}"
    echo -e "  ${BL}openclaw tui --message \"Wake up, my friend!\"${CL}"
    echo ""
    echo -e "  ${DM}# 4. After hatching, restore your production model:${CL}"
    echo -e "  ${BL}openclaw config set agents.defaults.model.primary <your-model>${CL}"
    echo -e "  ${BL}systemctl --user restart openclaw-gateway.service${CL}"
    echo ""
  fi
}

# =============================================================================
# Main
# =============================================================================
main() {
  step_ai_providers
  step_embeddings
  step_model_config
  step_telegram
  step_tailscale
  step_finalize
  print_summary
  step_launch
}

main "$@"
