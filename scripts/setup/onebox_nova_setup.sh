#!/usr/bin/env bash
# Retired historical setup script. Original preserved outside Git.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "Retired onebox importer. The original rewrote Git metadata and could push multiple branches; no files were changed."
echo "Use the reviewed canonical scripts: $ROOT/scripts/bootstrap.sh, $ROOT/scripts/start-all.sh, $ROOT/scripts/health-check.sh"
echo "Recovery copy: /home/justin/.local/share/repo-recovery/NOVA-SOVEREIGN-AI/legacy-repair-scripts-20261017/onebox_nova_setup.sh.before-safe-wrapper"
exit 2
