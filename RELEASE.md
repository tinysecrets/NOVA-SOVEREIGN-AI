# Release Checklist

## Verification

The repository includes a health-check script and a focused agent-team test module. From the root, use the declared project environment to run:

```bash
./scripts/health-check.sh
python3 -m pytest agent-team/tests/test_core.py
```

Run the test command in the environment provisioned by `scripts/bootstrap.sh` or use that environment's Python executable. Record real pass/skip/failure totals; a health-check pass alone is not proof that file/shell/Git actions are safe.

## Safety and deployment

1. Confirm startup defaults to loopback and only selects an approved Tailscale address when configured; reject wildcard/LAN exposure.
2. Verify secrets and runtime logs are ignored by Git and use synthetic configuration for tests.
3. Review every changed tool/action, destructive-command approval, provider fallback, and cross-app network route.
4. Do not start all apps, schedule background tasks, change repositories, or call remote providers as a side effect of tests.
5. Check `git diff --check`, staged files, and the exact commit. Keep a known-good commit and clear stop/rollback instructions.

Release only for private owner-operated use until an independently reviewed authentication and authorization model exists for public multi-user service.
