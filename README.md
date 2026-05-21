# agentfarm

Deployment scripts and templates for personal AI agents. Spin up a fully-configured agent container on Proxmox or any Debian/Ubuntu host with one command.

## Bots

| Bot | Status | What it is | Docs |
|-----|--------|-----------|------|
| **OpenClaw** | Stable | Autonomous agent (Node.js, [openclaw.ai](https://openclaw.ai)). Tiered model architecture, Telegram bridge, Tailscale, memory plugin, hatching ceremony. | [`openclaw/README.md`](openclaw/README.md) |
| **Hermes** | Planned (Phase 3) | [Nous Research Hermes Agent](https://hermes-agent.nousresearch.com) (Python). Self-improving, MIT-licensed, multi-platform messaging gateway, built-in FTS5 memory. | TBD |

## Quick start

### Proxmox host (unified menu — coming Phase 2)

```bash
bash -c "$(curl -fsSL pveAI.ivantsov.tech)"
```

Dialog menu picks the bot (OpenClaw / Hermes / Standard LXC), the Ubuntu release (26.04 LTS / 24.04 LTS / 25.04), and the container settings. Standard mode just provisions the LXC and stops — useful as a quick LXC factory.

### Bot-specific entrypoints

```bash
# OpenClaw on Proxmox host
bash -c "$(curl -fsSL pveClaw.ivantsov.tech)"

# OpenClaw standalone on any Debian/Ubuntu box
bash -c "$(curl -fsSL setupClaw.ivantsov.tech)"

# Hermes (Phase 3 — endpoints not yet live)
bash -c "$(curl -fsSL pveHermes.ivantsov.tech)"
bash -c "$(curl -fsSL setupHermes.ivantsov.tech)"
```

### Local clone

```bash
git clone https://github.com/Exploitacious/agentfarm.git
cd agentfarm
# Run any bot's script directly — see each bot's README
bash openclaw/proxmox.sh        # Proxmox host
sudo bash openclaw/install.sh   # Linux host
```

## Repo layout

```
agentfarm/
├── README.md            # this file
├── openclaw/            # OpenClaw bot — see openclaw/README.md
│   ├── proxmox.sh
│   ├── install.sh
│   ├── postinstall.sh
│   ├── reset.sh
│   └── templates/
├── hermes/              # Hermes bot (Phase 3)
├── proxmox/             # Unified PVE helper (Phase 2)
│   └── pve-helper.sh
└── IDEAS.md             # repo-scoped backlog
```

## Personal content stays out

Real `SOUL.md`, `IDENTITY.md`, `USER.md`, pre-filled `.env` files, and provider API keys never get committed. The repo ships placeholder templates only. Personal content is gitignored at the consumer container level (`~/.openclaw/`, `~/.hermes/`).

## License

See individual bot subdirs for upstream licenses. OpenClaw and Hermes are separate projects with their own terms.
