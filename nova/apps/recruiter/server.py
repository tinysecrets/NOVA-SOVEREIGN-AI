"""Recruiter API + all-day worker host.

Endpoints:
  GET  /api/recruiter/status            status, caps, gate, budget, counts
  GET  /api/recruiter/prospects         prospect list (paginated)
  GET  /api/recruiter/audit             recent audit events
  POST /api/recruiter/ingest            CSV upload of your own consent list
  POST /api/recruiter/gate              {"open": true|false} — approve cohort
  GET  /api/recruiter/unsubscribe       unsubscribe link target (opt-out honored)
  POST /api/recruiter/wake              run one tick on demand
"""
from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Dict, Optional

from recruit.config import load_config
from recruit.compliance import Compliance
from recruit.draft import draft_invite
from recruit.loop import Recruiter

cfg = load_config()
recruiter = Recruiter(cfg)

try:
    from fastapi import Body, FastAPI, HTTPException, Query
    from fastapi.responses import PlainTextResponse

    app = FastAPI(title="Recruiter", version="0.1.0")
    _worker: Optional[asyncio.Task] = None


    @app.on_event("startup")
    async def _start() -> None:
        global _worker
        if _worker is None:
            _worker = asyncio.create_task(recruiter.loop_forever())


    @app.on_event("shutdown")
    async def _stop() -> None:
        global _worker
        if _worker is not None:
            _worker.cancel()
            _worker = None


    @app.get("/api/recruiter/status")
    async def status() -> Dict[object, object]:
        counts = recruiter.compliance.counts_today()
        return {
            "dry_run": cfg.dry_run,
            "gate_open": recruiter.gate_open,
            "daily_cap": cfg.daily_cap,
            "max_per_hour": cfg.max_per_hour,
            "remaining_hour": recruiter.compliance.remaining_hour(),
            "remaining_day": recruiter.compliance.remaining_day(counts["sent_today"]),
            "budget_tokens_left": max(0, recruiter.budget_days - recruiter._today_budget()),
            "channels_enabled": list(cfg.channels_enabled.keys()),
            "prospects": recruiter.prospects.stats(),
            "counts": counts,
            "model_routine": cfg.model_routine,
            "model_high": cfg.model_high,
            "brain": cfg.brain,
            "telemetry": recruiter.telemetry(),
        }


    @app.get("/api/recruiter/prospects")
    async def prospects(limit: int = Query(50, le=500), offset: int = 0) -> Dict[str, object]:
        rows = recruiter.prospects.all()[offset: offset + limit]
        return {"total": len(recruiter.prospects.all()), "items": [p.as_dict() for p in rows]}


    @app.get("/api/recruiter/audit")
    async def audit(limit: int = Query(50, le=500)) -> Dict[str, object]:
        rows = list(recruiter.audit.rows())[-limit:][::-1]
        return {"total": recruiter.audit.count(), "items": rows}


    @app.post("/api/recruiter/ingest")
    async def ingest(csv_text: str = Body(...)) -> Dict[str, object]:
        result = recruiter.prospects.ingest_csv(csv_text)
        from recruit.store import now_iso

        recruiter.audit.append({"event": "ingest", "result": result, "at": now_iso()})
        return result


    @app.post("/api/recruiter/gate")
    async def gate(open: bool = Body(...)) -> Dict[str, object]:
        return recruiter.set_gate(open)


    @app.get("/api/recruiter/unsubscribe")
    async def unsubscribe(email: Optional[str] = None, t: Optional[str] = None) -> PlainTextResponse:
        if email:
            recruiter.compliance.opt_out(email, reason="unsubscribe_link")
        return PlainTextResponse("You are unsubscribed from Wah-Lah recruiter emails. Sorry to see you go.")


    @app.post("/api/recruiter/wake")
    async def wake() -> Dict[object, object]:
        return await asyncio.to_thread(recruiter.run_once)

except ImportError:  # fastapi unavailable: still usable as a worker library
    app = None
    print("fastapi not installed — server skipped; use the library API or `python -m recruit.loop`")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=cfg.host, port=cfg.port)