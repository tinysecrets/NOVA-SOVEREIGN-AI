#!/usr/bin/env bash
# NOVA — one-shot dependency bootstrap for the finished nova/apps stack
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/usr/bin:/usr/local/bin:${PATH:-}"

echo "======================================"
echo " NOVA BOOTSTRAP"
echo " Root: $ROOT"
echo "======================================"

have() { command -v "$1" >/dev/null 2>&1; }

# Prefer 3.12 for wheels; fall back to system python3.
if have python3.12; then
  PYTHON_BIN="$(command -v python3.12)"
elif have python3; then
  PYTHON_BIN="$(command -v python3)"
else
  echo "ERROR: python3 is required"
  exit 1
fi
echo "[py]  using ${PYTHON_BIN} ($("$PYTHON_BIN" --version 2>&1))"

need_cmds=(npm)
for c in "${need_cmds[@]}"; do
  if ! have "$c"; then
    echo "WARNING: missing optional command: $c (frontends may be skipped later)"
  fi
done

ensure_env() {
  local example="$1" target="$2"
  if [ -f "$example" ] && [ ! -f "$target" ]; then
    cp "$example" "$target"
    echo "[env] created $target from example"
  elif [ -f "$target" ]; then
    echo "[env] keep existing $target"
  else
    echo "[env] skip (no example): $example"
  fi
}

venv_ok() {
  local dir="$1"
  local py="${dir}/.venv/bin/python"
  [ -x "$py" ] || return 1
  "$py" -c "import sys" 2>/dev/null || return 1
  return 0
}

setup_backend() {
  local name="$1" dir="$2"
  if [ ! -f "${dir}/requirements.txt" ]; then
    echo "[skip] ${name} backend missing"
    return 0
  fi
  echo "[..]  ${name} backend deps"
  (
    cd "$dir"
    if ! venv_ok "$dir"; then
      rm -rf .venv
      "$PYTHON_BIN" -m venv .venv
    fi
    .venv/bin/pip install -q --upgrade pip setuptools wheel
    .venv/bin/pip install -q -r requirements.txt
    # Common runtime extras some trees omit from requirements.txt
    .venv/bin/pip install -q httpx 'python-jose[cryptography]' >/dev/null 2>&1 || true
  )
  ensure_env "${dir}/.env.example" "${dir}/.env"
  echo "[ok]   ${name} backend"
}

setup_frontend() {
  local name="$1" dir="$2"
  if [ ! -f "${dir}/package.json" ]; then
    echo "[skip] ${name} frontend missing"
    return 0
  fi
  echo "[..]  ${name} frontend deps"
  (
    cd "$dir"
    if [ ! -d node_modules ]; then
      npm install --legacy-peer-deps >/dev/null 2>&1 || npm install >/dev/null
    fi
  )
  ensure_env "${dir}/.env.example" "${dir}/.env"
  echo "[ok]   ${name} frontend"
}

setup_backend  "sovereign" "$ROOT/nova/apps/sovereign/backend"
setup_frontend "sovereign" "$ROOT/nova/apps/sovereign/frontend"
setup_backend  "sidekick"  "$ROOT/nova/apps/sidekick/backend"
setup_frontend "sidekick"  "$ROOT/nova/apps/sidekick/frontend"
setup_backend  "core"      "$ROOT/nova/apps/core/backend"
setup_frontend "core"      "$ROOT/nova/apps/core/frontend"
setup_backend  "recruiter" "$ROOT/nova/apps/recruiter"

chmod +x "$ROOT/scripts/"*.sh 2>/dev/null || true

echo ""
echo "======================================"
echo " BOOTSTRAP COMPLETE"
echo "======================================"
echo "1. Put keys in nova/apps/*/backend/.env (OPENROUTER_API_KEY, etc.)"
echo "2. Start:  ./scripts/start-all.sh"
echo "3. Check:  ./scripts/health-check.sh"
