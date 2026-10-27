# Recruiter — always-on Wah-Lah player acquisition

Own invitation worker for wah-lah.com. It runs all day, stays on the right side of
law and platform rules, uses paid Hermes models (not the crippled `:free` tier),
only contacts your own opted-in list, drives traffic to wah-lah handles, and
escalates to the Boss **only** when it genuinely needs a human.

## Hierarchy

```
Boss (jrs092393@gmail.com)
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
cp .env.example .env          # set RESEND_API_KEY, BOT_EMAIL, OPENROUTER_API_KEY
cd ../../..                   # repo root
./scripts/start-all.sh        # recruiter API on :8003
```

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
4. Set `.env`: `RECRUITER_DRY_RUN=false`, `RECRUITER_APPROVAL_GATE=false`
   (or keep the gate on and flip only the cohort via `POST /api/recruiter/gate {"open": true}`).
5. The worker ticks every `RECRUITER_HEARTBEAT_SEC` and respects `RECRUITER_DAILY_CAP`
   and `RECRUITER_MAX_PER_HOUR`.

## Compliance posture (kept by design)

- **Email (Resend):** verified `wah-lah.com` domain; CAN-SPAM footer (physical
  address, unsubscribe), honest subject, no winnings promises, sweepstakes
  "free to enter, no purchase necessary" note, AI disclosure.
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