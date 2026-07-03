# OpenClaw

Automates the deployment and configuration of [OpenClaw](https://openclaw.ai) on Proxmox LXC containers or any Debian/Ubuntu machine.

## What You Get

One command creates a ready-to-use OpenClaw environment:

- Ubuntu 24.04 LTS base with Node.js 22.x and build-essential
- Dedicated `claw` user with passwordless sudo and systemd lingering
- OpenClaw installed with the gateway running as a systemd user service
- Hardened config template (loopback gateway, log redaction, file permissions 600/700, tool policies)
- Memory plugin ([memory-lancedb-hybrid](https://github.com/CortexReach/memory-lancedb-pro)) installed post-hatch for persistent semantic + keyword memory
- Tailscale installed and ready for authentication
- Prompt injection defense and sub-agent delegation rules in agents.md.tpl (applied after hatching)
- Git-tracked `~/.openclaw/` config directory for rollback
- Automated daily backups (3 AM, 7-day retention) and 30-day memory cleanup cron
- System-wide PATH via `/etc/profile.d/openclaw.sh` (survives dotfile replacement)
- Node compile cache and `OPENCLAW_NO_RESPAWN` for faster CLI starts on LXC/VM hosts

After install, a post-install wizard handles everything that needs human input: AI providers, model roles, API keys, Telegram bot, Tailscale auth — then seeds BOOTSTRAP.md, swaps to an OpenAI model, launches the TUI to hatch the bot, and restores the production model afterward.

## Quick Start

### Proxmox Host (creates LXC + installs)

```bash
bash -c "$(curl -fsSL pveClaw.ivantsov.tech)"
```

Dialog-based TUI with Simple (recommended) and Advanced modes. Creates an unprivileged LXC with nesting, injects `/dev/net/tun` for Tailscale, then runs the install script inside.

### Existing Linux Machine (installs directly)

```bash
bash -c "$(curl -fsSL setupClaw.ivantsov.tech)"
```

Standalone mode on any Debian/Ubuntu machine. Templates are fetched from GitHub. Must be run as root.

### Local Clone

```bash
git clone https://github.com/Exploitacious/agentfarm.git
cd agentfarm/openclaw
bash proxmox.sh           # On Proxmox host — creates LXC + installs
# or
sudo bash install.sh      # On any machine — installs directly
```

## After Installation

1. **Reboot** the container to load PATH and services: `reboot`
2. **SSH in**: `ssh claw@<container-ip>` (password: `openclaw`)
3. **Change the default password**: `passwd`
4. **Run the post-install wizard**:

```bash
bash ~/agentfarm/openclaw/postinstall.sh
```

The wizard walks through six steps interactively:

| Step | What it does |
|------|-------------|
| AI Providers | Menu to add Anthropic, Gemini, OpenAI, OpenCode Zen/Go, Ollama (local or remote via OpenWebUI), DeepSeek, xAI, Mistral, OpenRouter, Together, LiteLLM, or any custom OpenAI-compatible endpoint |
| Embeddings | OpenAI API key for memory search (text-embedding-3-small) — separate from model providers |
| Model Roles | Choose "OpenCode Go 4 Mains" (current models), "OpenCode Go Future" (MiMo-V2 when available), or manually assign models per role: primary, fallbacks, sub-agents, heartbeat |
| Telegram | Bot token from @BotFather + your Telegram user ID for DM access |
| Tailscale | Authentication + Tailscale Serve on port 18789 |
| Finalize | Hook enablement, gateway restart, `openclaw doctor --fix`, git commit |
| Hatch | Lets you choose a hatch model, seeds BOOTSTRAP.md, launches TUI with "Wake up, my friend!", then restores production model and installs memory plugin |

All steps detect existing config and skip what's already done. Re-run safely at any time. At the end, the wizard handles the hatching process directly — no `openclaw onboard` involved. It presents a model selection menu for the hatch (GLM-5 recommended, Claude Sonnet for best quality, GPT-4o as fallback, or keep your current model), copies BOOTSTRAP.md from the shipped OpenClaw template into the workspace, and launches `openclaw tui --message "Wake up, my friend!"`. The bot follows the BOOTSTRAP.md instructions to interactively build its personality: SOUL.md, IDENTITY.md, and USER.md. When done, the bot deletes BOOTSTRAP.md on its own. After you exit the TUI, the script restores your production model and installs the memory plugin.

> **Note:** The memory plugin and all workspace content are intentionally NOT created before hatching. Any content in the workspace directory can trigger OpenClaw's `hasUserContent` check, which skips BOOTSTRAP.md auto-seeding and blocks the hatching dialogue. Our scripts bypass this entirely by seeding BOOTSTRAP.md manually and launching TUI directly.

### Scripted / Non-Interactive Mode

For automation or repeatable deployments, pass everything as flags:

```bash
bash ~/agentfarm/openclaw/postinstall.sh \
  --provider opencode-go --provider-key sk-... \
  --provider ollama --ollama-url https://openwebui.example.com \
  --primary-model opencode-go/kimi-k2.5 \
  --fallback-models "opencode-go/minimax-m2.7, opencode-go/glm-5" \
  --heartbeat-model opencode-go/minimax-m2.5 \
  --openai-key sk-... \
  --telegram-token 123456:ABCdef... \
  --telegram-user-id 123456789 \
  --tailscale-auth-key tskey-auth-... \
  --non-interactive
```

Use `--provider` / `--provider-key` pairs — repeat for each provider. Ollama supports both local installs and remote proxies (OpenWebUI) via `--ollama-url` with optional API key. In non-interactive mode, hatching is skipped — run the wizard interactively afterward to hatch, or seed BOOTSTRAP.md manually and launch `openclaw tui --message "Wake up, my friend!"`. Run `bash postinstall.sh --help` for all flags.

## File Structure

```
agentfarm/openclaw/
├── proxmox.sh           # Proxmox host script (creates LXC + runs install)
├── install.sh           # Install script (standalone or via Proxmox host)
├── postinstall.sh       # Post-install wizard (providers, models, Telegram, hatch)
├── reset.sh             # Reset agent (wipe memory/sessions/personality, re-hatch)
├── templates/
│   ├── openclaw.json.tpl    # Config template (gateway token auto-generated)
│   ├── soul.md.tpl          # Agent personality scaffold
│   └── agents.md.tpl        # Behavioral rules + prompt injection defense
└── README.md
```

## What Gets Installed Where

| Path | Purpose |
|------|---------|
| `~/.openclaw/openclaw.json` | Main config (mode 600) |
| `~/.openclaw/.env` | API keys for providers and embeddings (mode 600) |
| `~/.openclaw/agents/main/agent/auth-profiles.json` | Registered provider credentials |
| `~/.openclaw/workspace/SOUL.md` | Agent personality (generated by hatching process) |
| `~/.openclaw/workspace/AGENTS.md` | Behavioral rules (generated by hatching, customize after) |
| `~/.openclaw/workspace/USER.md` | User context for personalization (created post-hatch) |
| `~/.openclaw/workspace/skills/memory-lancedb-hybrid/` | Memory plugin (installed post-hatch by wizard) |
| `~/.config/systemd/user/openclaw-gateway.service` | Gateway systemd service |
| `/etc/profile.d/openclaw.sh` | System-wide PATH for `openclaw` CLI |
| `~/bin/backup-openclaw.sh` | Daily backup script |
| `~/backups/` | Backup tarballs (7-day retention) |

The daily backup includes `openclaw.json`, `.env`, `credentials/`, `workspace/`, and all `auth-profiles.json` files (provider credentials). Retained for 7 days.

## Customizing Templates

Edit files in `templates/` before running the install script to change what ships with every new container.

### openclaw.json.tpl

Config template with placeholder tokens:
- `__GATEWAY_TOKEN__` — auto-replaced with random hex during install
- `__TELEGRAM_BOT_TOKEN__` — set by the post-install wizard or manually

Default model config uses OpenCode Go ($10/month subscription) with a tiered architecture designed to spread rate limits across independent model pools. The "4 Mains" template ships as the default, using only the 4 models currently available:

| Role | Model | Rate Limit | Purpose |
|------|-------|-----------|---------|
| Primary | Kimi K2.5 | ~9,250/mo | Main conversation + reasoning (strongest available) |
| Fallback 1 | MiniMax M2.7 | ~70,000/mo | High-headroom fallback, keeps lights on |
| Fallback 2 | GLM-5 | ~5,750/mo | Secondary fallback for provider diversity |
| Sub-agents | MiniMax M2.7 | ~70,000/mo | Grunt work — research, tool calls, delegation |
| Heartbeat | MiniMax M2.5 | ~100,000/mo | Background pings, cheapest possible |

A "Future" template is also available for when MiMo-V2-Omni (multimodal, ~10,900/mo) and MiMo-V2-Pro (1M context, ~6,450/mo) launch on OpenCode Go.

Concurrency capped at 2 main / 3 sub-agents to avoid rate-limit walls on subscription throttling. Context pruning with 6h TTL, compaction flush at 40k tokens. Sub-agents use a separate model pool from the primary to preserve conversational quota. The agent is instructed (via AGENTS.md) to escalate to heavier models for complex tasks when available.

Default security posture (single-operator, personal assistant behind Tailscale):

| Setting | Value | Meaning |
|---------|-------|---------|
| `tools.exec.security` | `full` | All commands allowed (no allowlist) |
| `tools.exec.ask` | `off` | Bot runs commands without prompting |
| `tools.exec.host` | `gateway` | Commands run on the host, not sandboxed |
| `agents.defaults.elevatedDefault` | `full` | Elevated operations (sudo, rm, etc.) run without approval |
| `gateway.bind` | `loopback` | Gateway only reachable via localhost + Tailscale Serve |
| `gateway.auth.allowTailscale` | `true` | Tailscale connections trusted |

> **Note:** `tools.exec.security: "full"` means full *trust*, not full *restrictions*. It is the most permissive setting. If the bot claims it needs approval to run commands, it is misreading the config — no changes are needed.

### soul.md.tpl

Agent personality scaffold. Define who the agent is, its communication style, and safety guardrails.

### agents.md.tpl

Behavioral rules, prompt injection defense, and sub-agent delegation strategy. Ships with detection patterns for common attacks (instruction override, encoded payloads, typoglycemia, social engineering) plus tiered sub-agent guidance: default tier (MiniMax M2.7 for grunt work), escalation tier (MiMo-V2-Pro for complex reasoning / large context), and rate-limit awareness rules.

## Useful Commands

```bash
openclaw doctor --fix       # Health check and auto-fix
openclaw gateway status     # Gateway service info
openclaw logs --follow      # Real-time logs
openclaw tui                # Terminal UI
openclaw configure          # Interactive config wizard
openclaw skills list        # Available skills
openclaw security audit     # Security posture check
```

Shell aliases (added by install):
```bash
openclaw-update   # Update OpenClaw + restart gateway
openclaw-logs     # Shortcut for openclaw logs --follow
openclaw-status   # Shortcut for openclaw gateway status
openclaw-backup   # Run backup now
```

## Resetting the Agent

To wipe the agent's memory and personality without reinstalling OpenClaw:

```bash
bash ~/agentfarm/openclaw/reset.sh
```

This wipes memory (vector store + markdown logs), sessions (conversation history), and workspace identity files (SOUL.md, AGENTS.md, IDENTITY.md, etc.). The memory plugin is temporarily stashed outside the workspace so the hatching process sees a clean state. The script then presents a model selection menu (GLM-5, Claude Sonnet, GPT-4o, Kimi K2.5, current, or custom), seeds BOOTSTRAP.md from the OpenClaw template, and launches `openclaw tui --message "Wake up, my friend!"` to re-hatch directly — no `openclaw onboard` involved. After you exit the TUI, it restores the original model and memory plugin. All API keys, provider credentials, gateway tokens, and config settings are preserved throughout.

Options:

```bash
bash ~/agentfarm/openclaw/reset.sh --keep-soul     # Preserve personality, wipe only memory/sessions
bash ~/agentfarm/openclaw/reset.sh --full           # Also reset openclaw.json to template defaults
bash ~/agentfarm/openclaw/reset.sh --skip-hatch     # Don't launch onboard after reset
bash ~/agentfarm/openclaw/reset.sh --confirm        # Skip confirmation prompt (for scripting)
```

A timestamped backup is created automatically before every reset at `~/backups/openclaw-pre-reset-*.tar.gz`.

## Requirements

**Proxmox mode** (`proxmox.sh`):
- Proxmox VE 7.x or 8.x
- Root access on the Proxmox host
- Internet access from the host and container
- Ubuntu 24.04 LTS template (auto-downloaded if missing)

**Standalone mode** (`install.sh`):
- Debian/Ubuntu-based Linux (tested on Ubuntu 24.04)
- Root access
- Internet access

**Post-install wizard** (`postinstall.sh`):
- Run as the `claw` user (not root)
- OpenClaw must be installed and in PATH
