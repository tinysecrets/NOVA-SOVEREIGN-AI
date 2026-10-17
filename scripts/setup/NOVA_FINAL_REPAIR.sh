#!/usr/bin/env bash
# Retired historical repair pass. Original preserved outside Git under repo-recovery.
# This file used to delete frontend dependencies and invoke insecure wildcard launchers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "NOVA_FINAL_REPAIR.sh is a retired historical repair script. No files were changed."
echo "Use the reviewed canonical launcher instead: $ROOT/scripts/start-all.sh"
echo "Recovery copy: /home/justin/.local/share/repo-recovery/NOVA-SOVEREIGN-AI/legacy-repair-scripts-20261017/NOVA_FINAL_REPAIR.sh.before-safe-wrapper"
exit 2
