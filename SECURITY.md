# Security Policy

NOVA-SOVEREIGN-AI is a single-owner, self-hosted control plane that includes agent file, shell, and Git capabilities across multiple apps. Treat model-provider keys, admin credentials, JWT secrets, `.env` files, local databases, conversations, uploaded documents, and runtime logs as sensitive. Never commit or share secrets, user documents, or unredacted command logs.

The safe network posture is loopback or an explicitly approved private Tailscale address. The API is not a public multi-user service and must not be port-forwarded or published to the internet until general authentication, authorization, least-privilege tool controls, and audit protections are verified. Keep tailnet ACLs narrow and avoid wildcard/LAN binds. Tests should use synthetic data and local providers/mocks; they must not mutate real user files, repositories, or remote services.

Before enabling shell/Git tools or background tasks, preserve approval and dry-run guards. Report vulnerabilities privately to the project owner with a synthetic reproduction and no credentials or private data.
