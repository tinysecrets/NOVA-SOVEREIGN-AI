#!/usr/bin/env bash
# Retired historical setup script. Original preserved outside Git.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "Retired upgrade script. The original copied private .env files into an in-repo backup and installed into obsolete checkouts; no files were changed."
echo "Use the reviewed canonical scripts: $ROOT/scripts/bootstrap.sh, $ROOT/scripts/start-all.sh, $ROOT/scripts/health-check.sh"
echo "Recovery copy: /home/justin/.local/share/repo-recovery/NOVA-SOVEREIGN-AI/legacy-repair-scripts-20261017/NOVA_UPGRADE_FINAL.sh.before-safe-wrapper"
exit 2
