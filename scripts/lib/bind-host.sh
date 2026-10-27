#!/usr/bin/env bash
# Shared safe bind selection for the personal, self-hosted NOVA stack.
# Prefer the authorized Tailscale interface; otherwise expose services only on loopback.
# LAN/WAN wildcard binds are deliberately rejected because Sovereign exposes agent tools.

nova_bind_host() {
  local candidate="${1:-}"
  if [[ -z "$candidate" ]] && command -v tailscale >/dev/null 2>&1; then
    candidate="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
  fi
  candidate="${candidate:-127.0.0.1}"
  if [[ "$candidate" =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ || "$candidate" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  echo "ERROR: NOVA_BIND_HOST must be loopback or a Tailscale CGNAT address (100.64.0.0/10); refusing: $candidate" >&2
  return 1
}
