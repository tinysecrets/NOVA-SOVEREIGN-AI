#!/usr/bin/env bash
# Compatibility alias for older desktop shortcuts; canonical startup logic lives in scripts/start-all.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$ROOT/scripts/start-all.sh" "$@"
