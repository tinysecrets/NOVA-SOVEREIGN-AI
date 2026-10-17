# scripts/

Operational scripts for the NOVA Sovereign AI platform.

## Run the full finished stack

From the repository root:

```bash
chmod +x scripts/*.sh
./scripts/bootstrap.sh
./scripts/start-all.sh
```

Then verify:

```bash
./scripts/health-check.sh
```

Stop everything started by the launcher:

```bash
./scripts/stop-all.sh
```

## Layout

| Path | Purpose |
|------|---------|
| `bootstrap.sh` | Create venvs, install deps, seed `.env` from examples |
| `start-all.sh` | Start Sovereign, Sidekick, and Core APIs + UIs |
| `health-check.sh` | Probe service ports on the selected private/loopback binding |
| `stop-all.sh` | Stop processes tracked in `logs/pids/` |
| `setup/` | Historical setup, repair, upgrade, and import utilities |
| `logs/` | Archived upgrade log + runtime logs/pids |

## Canonical ports

The canonical launcher uses the machine's Tailscale IPv4 address when available, otherwise loopback. Use the actual address reported by `start-all.sh`; do not assume `localhost` is reachable from the S22.

| Service | Port | Default binding |
|---------|------|-----------------|
| Sovereign UI | 3000 | Tailscale or loopback |
| Sidekick UI | 5173 | Tailscale or loopback |
| Core UI | 3002 | Tailscale or loopback |
| Sovereign API | 8000 | Tailscale or loopback |
| Sidekick API | 8001 | Tailscale or loopback |
| Core API | 8002 | Tailscale or loopback |
| Recruiter API | 8003 | Loopback only |

## Setup utilities (`setup/`)

- `build_nova.sh` — standalone-project generator. It emits the Vite 8 + Tailwind 4 toolchain and uses loopback/private Tailscale binding by default.
- `NOVA_START_ALL.sh` and `NOVA_HEALTH_CHECK.sh` — compatibility aliases for the canonical launch/health scripts.
- `onebox_nova_setup.sh`, `NOVA_UPGRADE_FINAL.sh`, `NOVA_FINAL_REPAIR.sh`, `NOVA_LAST_MILE.sh`, `NOVA_FINAL_SWEEP.sh`, and `NOVA_CLEAN_ARCHIVES.sh` are retired fail-closed wrappers. Their original contents are preserved outside the repository at `/home/justin/.local/share/repo-recovery/NOVA-SOVEREIGN-AI/legacy-repair-scripts-20261017/`; do not restore them as normal launchers because they could rewrite Git branches, modify sibling repos, copy private `.env` files into the repository, remove archived projects, or bind APIs to every interface.

Use only `./scripts/bootstrap.sh`, `./scripts/start-all.sh`, `./scripts/health-check.sh`, and `./scripts/stop-all.sh` for normal operation.
