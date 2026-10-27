#!/usr/bin/env bash
# Recruiter fail-safe.
# Runs every 5 min via cron (and once on @reboot). Keeps the worker API alive,
# detects a dead/stuck ticker, and breathes the daemon back to life. It never
# sends on its own — the daemon is the single tick source, so no double-sends.
set -u

# cron has a minimal PATH — make sure core tools resolve
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/nova/apps/recruiter"
PORT="${RECRUITER_PORT:-8003}"
ROLL="${ROOT}/scripts/logs/pids"
PIDF="${ROLL}/recruiter-api.pid"
LOCKF="${ROLL}/recruiter-failsafe.lock"
LOG="${ROOT}/scripts/logs/recruiter.log"
PY="${APP}/.venv/bin/python"
[ -x "$PY" ] || PY="python3"
STALE_AFTER="${RECRUITER_STALE_AFTER:-600}"

mkdir -p "$ROLL"
exec 9>"$LOCKF"
flock -n 9 || exit 0

url="http://127.0.0.1:${PORT}/api/recruiter/status"
status="$(curl -sf --max-time 10 "$url" 2>/dev/null)" || status=""

alive() {
  [ -n "$status" ] || return 1
  "$PY" - "$status" "$STALE_AFTER" <<'PY'
import json, sys, datetime
body, stale_after = sys.argv[1], int(sys.argv[2])
d = json.loads(body)
t = d.get("telemetry") or {}
if not t.get("last_tick_at"):
    print("no_last_tick"); raise SystemExit(1)
if t.get("last_tick_ok") is False:
    print("tick_failed"); raise SystemExit(1)
last = datetime.datetime.fromisoformat(t["last_tick_at"])
if (datetime.datetime.utcnow().replace(tzinfo=last.tzinfo) - last).total_seconds() > stale_after:
    print("stale"); raise SystemExit(1)
raise SystemExit(0)
PY
}

start() {
  echo "[$(date -Is)] recruiter dead or stale — restarting"
  (
    cd "$APP"
    setsid nohup "$PY" -m uvicorn server:app --host 127.0.0.1 --port "$PORT" \
      >>"$LOG" 2>&1 < /dev/null &
  )
  sleep 3
  pid="$(ss -ltnp 2>/dev/null | grep -F ":$PORT " | grep -oP 'pid=\K[0-9]+' | head -1)"
  echo "${pid:-0}" > "$PIDF"
  curl -sf --max-time 10 "$url" >/dev/null && echo "[$(date -Is)] recruiter up (pid ${pid:-unknown})" || echo "[$(date -Is)] restart FAILED — check $LOG"
}

if alive; then
  :
else
  start
fi