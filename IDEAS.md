# agentfarm — IDEAS

Repo-scoped backlog. Cluster-wide ideas live in `~/COWORK/PROJECTS/Exploitacious/IDEAS.md`.

## Phase tracker

- **Phase 1 (done — 2026-05-21):** Renamed `OpenClaw` → `agentfarm`. Restructured into `openclaw/` subdir, dropped `openclaw-` prefix on filenames. Top-level umbrella README. `projects-map.md` updated.
- **Phase 2 (next):** Unified `proxmox/pve-helper.sh` with menu (OpenClaw / Hermes / Standard-no-install) + Ubuntu OS picker (26.04 / 24.04 / 25.04). DNS: add `pveAI.ivantsov.tech` → unified menu.
- **Phase 3:** Hermes pack (`hermes/install.sh`, `hermes/postinstall.sh`, `hermes/reset.sh`, templates). Mirror OpenClaw structure but thinner — upstream `hermes setup` does heavy lifting. Same Tailscale + cgroup pattern. Daily backup cron (Hermes ships none). DNS: `pveHermes.ivantsov.tech` + `setupHermes.ivantsov.tech`.
- **Phase 4:** DNS + docs sync, live test deploy.

## Deferred — `shared/lib.sh` refactor

After Hermes lands and we have duplicated `msg_ok`/`msg_error`/`msg_info`/`msg_warn`/color helpers across both packs, factor them into `shared/lib.sh`. Skipped during Phase 1 because curl|bash mode can't source siblings without first fetching them, and per-script self-containment is more important than DRY at this scale.

When we do this: each script's curl|bash header inlines a `eval "$(curl -fsSL ${REPO_RAW}/shared/lib.sh)"` or similar. Or just keep helpers inlined and accept the duplication — judgment call once we see the actual diff between OpenClaw and Hermes script bodies.

## Other ideas

- (none yet — drop new bot ideas here)
