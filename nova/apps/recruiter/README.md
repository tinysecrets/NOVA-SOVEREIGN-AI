# Recruiter — consent-based Wah-Lah invitations

Invitation worker for wah-lah.com. It defaults to dry-run, drafts only for contacts
who explicitly opted in, and keeps a human approval gate before live sends. Remote
inference is restricted to OpenRouter model IDs ending in `:free`; if that BYOK key
is absent or the free model is unavailable, the worker uses local Ollama only. Paid
cloud routes are intentionally disabled.

## Hierarchy

```
Boss (set `BOSS_EMAIL` in the private environment file)
  └─ Recruitment pipeline (this app)         order-takers from Genie/Sovereign
        write ─▶ qa ─▶ repair ─▶ report       (same shape as the agent team)
              └▶ senders: email / discord / telegram
        escalates to Boss: gate, opt-out or bounce bursts, P0 QA, budget, crash
```

The worker is a long-lived service inside the NOVA stack (API :8003) and follows
the chain of command: specialist rounds produce copy, hard compliance rules act
as the blocking QA, and the Boss is the only person who can flip the gate open.

## Quick start

```bash
cp nova/apps/recruiter/.env.example nova/apps/recruiter/.env
# Use a real, owner-supplied POSTAL_ADDRESS before live mail.
# Generate a unique 32+ character UNSUBSCRIBE_SECRET and set the public HTTPS
# UNSUBSCRIBE_BASE_URL to the host that serves /api/recruiter/unsubscribe.
# RESEND_API_KEY is required for sending; OPENROUTER_API_KEY is optional BYOK.
./scripts/start-all.sh        # recruiter API on localhost:8003 only
```

Do not expose port 8003 publicly. The example environment intentionally leaves
postal address and unsubscribe settings blank, so live email fails closed until
an operator configures those values.

Enforce the safety rails:

```bash
RECRUITER_DRY_RUN=true        # default: audits drafts, NEVER sends
RECRUITER_APPROVAL_GATE=true  # default: requires explicit gate flip
POSTAL_ADDRESS="<real address>"   # required before live email (CAN-SPAM)
```

## Loading your own consent list

`POST /api/recruiter/ingest` with CSV body:

```csv
email,name,source,consent
jordan@example.com,Jordan,existing member,true
```

Rules enforced at ingest: valid email, consent must be true, previously
opted-out addresses are skipped, duplicates are dropped.

## Go-live (human-in-the-loop)

1. Load the list.
2. `GET /api/recruiter/status` → confirm `dry_run: true`, drafts pending.
3. Review drafts in `GET /api/recruiter/audit`.
4. Only after the owner reviews the drafts, configures a real postal address and signed unsubscribe settings, and verifies the consent list, set `RECRUITER_DRY_RUN=false`. Keep `RECRUITER_APPROVAL_GATE=true` and open the first cohort explicitly through the localhost-only API. The worker's hard gate remains closed until that operator action.
5. The worker ticks every `RECRUITER_HEARTBEAT_SEC` and respects `RECRUITER_DAILY_CAP` and `RECRUITER_MAX_PER_HOUR`.

## Compliance posture (kept by design)

- **Email (Resend):** live sending requires a real postal address, a public HTTPS
  unsubscribe base URL, a unique 32+ character unsubscribe secret, and a Resend key.
  Email headers include signed one-click unsubscribe links; invalid tokens are rejected.
  Copy includes the free-entry note and AI disclosure and blocks winnings promises.
- **Opt-out:** honored instantly; bounces auto opt the contact out.
- **Rate ceilings:** per-hour and per-day caps; per-prospect retry intervals;
  daily token budget. Escalates when any budget is hit.
- **Platform rules:** Discord/Telegram only carry opt-in traffic (consent list or
  explicit `opt_in_via_bot`); no mass unsolicited DMs; X/IG automation is
  disabled by default.
- **Hard blocks:** banned phrasing (prize/winnings/urgency/payment) stops the
  send; every blocked draft is audited.

## API

| Method | Path | Purpose |
|---|---|---|
| GET  | `/api/recruiter/status` | caps, gate, budget, counts |
| GET  | `/api/recruiter/prospects` | your list, paginated |
| GET  | `/api/recruiter/audit` | last events (drafts, sends, blocks) |
| POST | `/api/recruiter/ingest` | CSV upload |
| POST | `/api/recruiter/gate` | `{"open": true|false}` |
| GET  | `/api/recruiter/unsubscribe` | opt-out link target |
| POST | `/api/recruiter/wake` | one tick now |

CLI: `python3 -m recruit.loop --once` runs a single tick; no FastAPI needed.

## Tests

```bash
python3 -m unittest discover -s tests
```