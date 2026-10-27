#!/usr/bin/env bash
# Retired historical repair pass. Original preserved outside Git under repo-recovery.
# This file used to edit another checkout and rewrite multiple scripts; it is now fail-safe.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "NOVA_LAST_MILE.sh is a retired historical repair script. No files were changed."
echo "Use the reviewed canonical launcher instead: $ROOT/scripts/start-all.sh"
echo "Recovery copy: /home/justin/.local/share/repo-recovery/NOVA-SOVEREIGN-AI/legacy-repair-scripts-20261017/NOVA_LAST_MILE.sh.before-safe-wrapper"
exit 2
