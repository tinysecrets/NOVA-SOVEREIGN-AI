#!/usr/bin/env bash
# NOVA — live health check for the full platform
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/bind-host.sh"
NOVA_BIND_HOST="$(nova_bind_host "${NOVA_BIND_HOST:-}")" || exit 1

echo "================================="
echo " NOVA LIVE HEALTH CHECK"
echo "================================="

check() {
  local label="$1" url="$2"
  echo ""
  echo "[${label}] ${url}"
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -sS -o /tmp/nova-health.out -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    echo "HTTP ${code}"
    head -c 400 /tmp/nova-health.out 2>/dev/null; echo
  else
    echo "curl not installed"
  fi
}

check "SOVEREIGN API" "http://${NOVA_BIND_HOST}:8000/api/health"
check "SIDEKICK API"  "http://${NOVA_BIND_HOST}:8001/api/health"
check "CORE API docs" "http://${NOVA_BIND_HOST}:8002/docs"
check "SOVEREIGN UI"  "http://${NOVA_BIND_HOST}:3000"
check "SIDEKICK UI"   "http://${NOVA_BIND_HOST}:5173"
check "CORE UI"       "http://${NOVA_BIND_HOST}:3002"

echo ""
echo "================================="
echo " HEALTH CHECK COMPLETE"
echo "================================="
