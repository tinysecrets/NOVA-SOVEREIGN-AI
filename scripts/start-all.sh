#!/usr/bin/env bash
# NOVA — start the full finished platform (sovereign + sidekick + core)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT}/scripts/logs/runtime"
PID_DIR="${ROOT}/scripts/logs/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

export PATH="/usr/bin:/usr/local/bin:${PATH:-}"

echo "======================================"
echo " NOVA FULL PLATFORM START"
echo " Root: $ROOT"
echo "======================================"

have() { command -v "$1" >/dev/null 2>&1; }

start_backend() {
  local name="$1" dir="$2" port="$3"
  local host="${4:-0.0.0.0}"
  local log="${LOG_DIR}/${name}-api.log"
  local pidf="${PID_DIR}/${name}-api.pid"

  if [ ! -f "${dir}/server.py" ]; then
    echo "[skip] ${name} backend missing: ${dir}"
    return 0
  fi

  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    echo "[ok]   ${name} API already running (pid $(cat "$pidf")) :${port}"
    return 0
  fi

  echo "[..]  Starting ${name} API on :${port}"
  (
    cd "$dir"
    local py="python3"
    if [ -x .venv/bin/python ]; then
      py="$(pwd)/.venv/bin/python"
    elif [ -x .venv/bin/python3 ]; then
      py="$(pwd)/.venv/bin/python3"
    fi
    if ! "$py" -c "import uvicorn" 2>/dev/null; then
      echo "[!!]  ${name}: uvicorn missing in ${py}. Run ./scripts/bootstrap.sh" >&2
    fi
    nohup "$py" -m uvicorn server:app --host "$host" --port "$port" \
      >"$log" 2>&1 &
    echo $! >"$pidf"
  )
  echo "[ok]   ${name} API pid $(cat "$pidf")  log: $log"
}

start_frontend() {
  local name="$1" dir="$2" port="$3" cmd="$4"
  local log="${LOG_DIR}/${name}-ui.log"
  local pidf="${PID_DIR}/${name}-ui.pid"

  if [ ! -f "${dir}/package.json" ]; then
    echo "[skip] ${name} frontend missing: ${dir}"
    return 0
  fi

  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    echo "[ok]   ${name} UI already running (pid $(cat "$pidf")) :${port}"
    return 0
  fi

  echo "[..]  Starting ${name} UI on :${port}"
  (
    cd "$dir"
    if [ ! -d node_modules ]; then
      npm install --legacy-peer-deps >/dev/null 2>&1 || npm install >/dev/null 2>&1 || true
    fi
    export PORT="$port"
    export BROWSER=none
    # Vite uses --port; CRA uses PORT env
    nohup bash -lc "$cmd" >"$log" 2>&1 &
    echo $! >"$pidf"
  )
  echo "[ok]   ${name} UI pid $(cat "$pidf")  log: $log"
}

# Prefer consolidated nova/apps layout; fall back to legacy root folders.
SOVEREIGN_BE="${ROOT}/nova/apps/sovereign/backend"
SOVEREIGN_FE="${ROOT}/nova/apps/sovereign/frontend"
SIDEKICK_BE="${ROOT}/nova/apps/sidekick/backend"
SIDEKICK_FE="${ROOT}/nova/apps/sidekick/frontend"
CORE_BE="${ROOT}/nova/apps/core/backend"
RECRUITER_BE="${ROOT}/nova/apps/recruiter"

[ -f "${SOVEREIGN_BE}/server.py" ] || SOVEREIGN_BE="${ROOT}/archive/legacy/NOVA-SOVERIGN/backend"
[ -f "${SOVEREIGN_FE}/package.json" ] || SOVEREIGN_FE="${ROOT}/archive/legacy/NOVA-SOVERIGN/frontend"
[ -f "${SIDEKICK_BE}/server.py" ] || SIDEKICK_BE="${ROOT}/archive/legacy/genie-sidekick/backend"
[ -f "${SIDEKICK_FE}/package.json" ] || SIDEKICK_FE="${ROOT}/archive/legacy/genie-sidekick/frontend"
[ -f "${CORE_BE}/server.py" ] || CORE_BE="${ROOT}/archive/legacy/real_Genie/backend"

if ! have python3; then
  echo "ERROR: python3 is required"
  exit 1
fi
if ! have npm; then
  echo "WARNING: npm not found — frontends will be skipped"
fi

# Ports (canonical finished stack)
#   Sovereign API 8000  |  Sidekick API 8001  |  Core API 8002
#   Sovereign UI  3000  |  Sidekick UI  5173
start_backend "sovereign" "$SOVEREIGN_BE" 8000
start_backend "sidekick"  "$SIDEKICK_BE"  8001
start_backend "core"      "$CORE_BE"      8002
start_backend "recruiter" "$RECRUITER_BE" 8003 127.0.0.1

if have npm; then
  start_frontend "sovereign" "$SOVEREIGN_FE" 3000 "npm start"
  start_frontend "sidekick"  "$SIDEKICK_FE"  5173 "npm run dev -- --host 0.0.0.0 --port 5173"
fi

echo ""
echo "======================================"
echo " NOVA ONLINE"
echo "======================================"
echo " Sovereign UI   http://localhost:3000"
echo " Sidekick UI    http://localhost:5173"
echo " Sovereign API  http://localhost:8000"
echo " Sidekick API   http://localhost:8001"
echo " Core API       http://localhost:8002"
echo " Recruiter API  http://localhost:8003"
echo ""
echo " Health check:  ./scripts/health-check.sh"
echo " Stop all:      ./scripts/stop-all.sh"
echo " Runtime logs:  ${LOG_DIR}/"
