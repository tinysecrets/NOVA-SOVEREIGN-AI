#!/usr/bin/env bash
# NOVA MASTER — dev launcher for Fedora. Starts MongoDB (podman), backend, frontend.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ROOT/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/bind-host.sh"
NOVA_BIND_HOST="$(nova_bind_host "${NOVA_BIND_HOST:-}")" || exit 1
export NOVA_BIND_HOST

echo ">> 1/3  MongoDB (podman)"
if command -v podman >/dev/null 2>&1; then
  if ! podman ps --format '{{.Names}}' | grep -q '^nova-mongo$'; then
    if podman ps -a --format '{{.Names}}' | grep -q '^nova-mongo$'; then
      podman start nova-mongo
    else
      podman run -d --name nova-mongo -p 127.0.0.1:27017:27017 docker.io/library/mongo:7
    fi
  fi
else
  echo "!! podman not found. Install it (sudo dnf install -y podman) or run MongoDB yourself on :27017"
fi

echo ">> 2/3  Backend (FastAPI :8000)"
cd "$ROOT/backend"
[ -d .venv ] || python3 -m venv .venv
source .venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt
export CORS_ORIGINS="${NOVA_SOVEREIGN_CORS_ORIGINS:-http://${NOVA_BIND_HOST}:3000,http://127.0.0.1:3000,http://localhost:3000}"
uvicorn server:app --host "$NOVA_BIND_HOST" --port 8000 > "$ROOT/backend/backend.log" 2>&1 &
BACK_PID=$!
echo "$BACK_PID" > "$ROOT/.backend.pid"
deactivate || true
echo "   backend pid $BACK_PID (logs: backend/backend.log)"

cleanup() { echo; echo ">> stopping backend"; kill "$BACK_PID" 2>/dev/null || true; exit 0; }
trap cleanup INT TERM

echo ">> 3/3  Frontend (Vite :3000)"
cd "$ROOT/frontend"
if [ ! -d node_modules ]; then
  if [ -f package-lock.json ]; then
    npm ci --no-audit --no-fund
  else
    npm install --no-audit --no-fund
  fi
fi
export VITE_BACKEND_URL="${VITE_BACKEND_URL:-http://${NOVA_BIND_HOST}:8000}"
npm run dev -- --host "$NOVA_BIND_HOST" --port 3000
