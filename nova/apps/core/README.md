# NOVA Core / Ember — local inference by default

The backend uses local Ollama for both chat and memory extraction. The default model is `hermes3:8b`, already available on the workstation. Override `OLLAMA_MODEL` only to select another model present in the local Ollama inventory. No remote inference key is needed.

The safe template is `nova/apps/core/backend/.env.example`. First run `./scripts/bootstrap.sh` from the repository root; it copies the example into `.env` only when `.env` does not already exist. The default database is the separate `ember` database on local MongoDB. Existing `.env` files are preserved and must stay out of Git.

From the repository root:

```bash
./scripts/bootstrap.sh
ollama list
./scripts/start-all.sh
./scripts/health-check.sh
```

The canonical stack uses Core API port `8002` and Core UI port `3002`; the launcher binds to the private Tailscale address when available, otherwise to loopback.

The frontend production build is checked with `npm run build` from `nova/apps/core/frontend`.

Core backend integration tests are intentionally skipped unless pointed at a disposable test API with explicit mutation opt-in. Use `EMBER_TEST_API_URL` and `EMBER_TEST_ALLOW_MUTATIONS=1`; the auth-isolation tests also require seeded `TOKEN_A` and `TOKEN_B`. These tests create/delete records and can invoke model-backed chat, so do not aim them at production.
