# NOVA Platform Status

This file replaces the stale September 2026 repair-era status report. The active source of truth is the repository root README and `scripts/README.md`.

## Canonical entry points

- Bootstrap dependencies: `./scripts/bootstrap.sh`
- Start services: `./scripts/start-all.sh`
- Verify: `./scripts/health-check.sh`
- Stop: `./scripts/stop-all.sh`

## Current design boundaries

- Model routing is free-first; OpenRouter choices must end in `:free`, Google is excluded, and the local Ollama model is the no-key path.
- The default launch interface is loopback or the machine's Tailscale IPv4 address. LAN/wildcard binds are rejected by the canonical launcher.
- The Recruiter API stays on loopback. Its email sender stays dry-run by default and requires a real postal address, Resend credentials, and a strong signed-unsubscribe setup before any live sending.
- This is a single-owner self-hosted control plane. The agent-tool API does not yet implement a general user login; keep it on loopback/private Tailscale with restrictive tailnet ACLs. Do not publish it to the internet.
- Historical repair/import scripts were replaced with fail-closed wrappers; original versions are preserved outside this repository under `/home/justin/.local/share/repo-recovery/NOVA-SOVEREIGN-AI/legacy-repair-scripts-20261017/`.

See current test/build output and Git commit history for verified release status. No public deployment or OS reboot is implied by this status note.
