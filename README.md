# NOVA Sovereign AI

Unified workspace for the NOVA Sovereign platform: chat, agent team, and sidekick apps on a free-first OpenRouter / local Ollama stack. Remote OpenRouter model selections are restricted to explicit `:free` model IDs; Google models and paid cloud routing are excluded by policy.

## Repository layout

```
nova/apps/
  sovereign/     # Primary NOVA UI + FastAPI backend
  sidekick/      # Genie Sidekick (Vite UI + API)
  core/          # Core / Real Genie API
nova/config/     # Shared models + pipeline config
nova/docs/       # Deployment notes
scripts/         # Bootstrap, start/stop/health, setup utilities
archive/legacy/  # Historical duplicate trees (not used day-to-day)
agent-team/      # Agent orchestration helpers
```

## Prerequisites

- Python 3.12 recommended (3.10+ works; avoid 3.14 for wheels)
- Node.js 18+ and npm
- Optional: MongoDB on `:27017` (podman/docker), Ollama for local models

```bash
# Fedora example
sudo dnf install -y python3 python3-pip nodejs npm
```

## Configure secrets

OpenRouter BYOK is optional. The default model is a free-tier model; leave the key empty to use local Ollama when available. Never place live credentials in source control.

```bash
# Example for sovereign backend
cp nova/apps/sovereign/backend/.env.example nova/apps/sovereign/backend/.env 2>/dev/null || true
# Edit and set:
# OPENROUTER_API_KEY=sk-or-...
```

Legacy trees also use `backend/.env` / `.env.example` under each app.

## Run the full project

From the repository root:

```bash
chmod +x scripts/*.sh
./scripts/bootstrap.sh   # once: venvs, npm install, .env from examples
./scripts/start-all.sh
```

The launcher binds to the Tailscale IPv4 address when Tailscale is active; otherwise it binds to loopback. It refuses wildcard/LAN binds by default because the Sovereign API includes agent file/shell/Git tools. This repository is a single-owner, self-hosted control plane—not a public multi-user service: API requests are not protected by a general user login. Keep it on loopback/private Tailscale, enforce your tailnet ACLs, and do not port-forward or publish it to the internet until authenticated access and least-privilege controls are implemented.

```bash
# Show the same address policy used by start-all.sh
source scripts/lib/bind-host.sh
nova_bind_host "${NOVA_BIND_HOST:-}"
```

Open the UI/API on the selected bind host (for example, `http://100.x.y.z:3000` from your S22 over Tailscale, or `http://127.0.0.1:3000` when loopback is selected). `NOVA_BIND_HOST` may be set to `127.0.0.1` or an address in the Tailscale `100.64.0.0/10` range; other bind addresses are rejected.

Health check:

```bash
./scripts/health-check.sh
```

Stop:

```bash
./scripts/stop-all.sh
```

Runtime logs live under `scripts/logs/runtime/`.

## Run Sovereign only

```bash
cd nova/apps/sovereign
./run.sh
```

This starts MongoDB (podman if present), the FastAPI backend, and the Vite frontend.

## Install dependencies manually

Backends:

```bash
cd nova/apps/sovereign/backend && python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
# Loopback-only by default; set NOVA_BIND_HOST to your Tailscale IP for authorized devices.
uvicorn server:app --host "${NOVA_BIND_HOST:-127.0.0.1}" --port 8000
```

Frontends:

```bash
# Same trusted host as the API, so authorized tailnet devices can reach the UI.
export NOVA_BIND_HOST="$(tailscale ip -4 | head -n 1)"  # omit to use loopback
cd nova/apps/sovereign/frontend && npm install && VITE_BACKEND_URL="http://$NOVA_BIND_HOST:8000" npm run dev -- --host "$NOVA_BIND_HOST" --port 3000
cd nova/apps/sidekick/frontend && npm install && HOST="$NOVA_BIND_HOST" VITE_BACKEND_URL="http://$NOVA_BIND_HOST:8001" npm run dev -- --host "$NOVA_BIND_HOST" --port 5173
```

## More

- Platform scripts index: [`scripts/README.md`](scripts/README.md)
- Deployment notes: [`nova/docs/DEPLOYMENT.md`](nova/docs/DEPLOYMENT.md)
- Archived setup/repair tools: `scripts/setup/`

## License

See [`LICENSE`](LICENSE).
