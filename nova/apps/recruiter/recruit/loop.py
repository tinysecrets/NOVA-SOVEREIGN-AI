"""The all-day worker loop.

Picks due opted-in prospects, runs the copy pipeline, respects the approval
gate + rate ceilings, sends through the enabled channel, audits everything,
and escalates to the Boss only when it genuinely needs a human.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from pathlib import Path
from typing import Any, Callable, Dict

from .compliance import Compliance
from .config import RecruiterConfig
from .draft import draft_invite
from .escalation import send_alert
from .prospects import ProspectStore
from .senders import Senders
from .store import JsonlStore, now_iso

log = logging.getLogger("recruiter")

STATE_DIR_ATTR = "data_dir"


def _read_json(path: Path, default: Dict[str, Any]) -> Dict[str, Any]:
    if path.exists():
        try:
            return json.loads(path.read_text())
        except Exception:  # noqa: BLE001
            return dict(default)
    return dict(default)


def _write_json(path: Path, data: Dict[str, Any]) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True))


class Recruiter:
    def __init__(self, cfg: RecruiterConfig, llm: Callable = None):
        self.cfg = cfg
        self.llm = llm
        self.compliance = Compliance(cfg)
        self.prospects = ProspectStore(cfg, self.compliance)
        self.senders = Senders(cfg)
        self.audit = self.compliance.audit
        self.gate_path = cfg.data_dir / "gate.json"
        self.budget_path = cfg.data_dir / "budget.json"
        self.alerts_path = cfg.data_dir / "alerts.json"
        self.budget_days = int(cfg.yaml.get("models", {}).get("budget_tokens_per_day", 500000))
        self.last_tick_at: str = ""
        self.last_tick_ok: bool = True
        self.last_tick_err: str = ""

    # ------------- gate -------------
    @property
    def gate_open(self) -> bool:
        if self.cfg.dry_run:
            return True
        state = _read_json(self.gate_path, {"open": False})
        return bool(state.get("open"))

    def set_gate(self, open_gate: bool) -> Dict[str, object]:
        state = _read_json(self.gate_path, {})
        state["open"] = bool(open_gate)
        state["updated_at"] = now_iso()
        _write_json(self.gate_path, state)
        self.audit.append({"event": "gate", "open": bool(open_gate), "at": now_iso()})
        return state

    # ------------- budget -------------
    def _today_budget(self) -> int:
        state = _read_json(self.budget_path, {})
        return int(state.get(now_iso()[:10], 0))

    def _add_budget(self, tokens: int) -> None:
        state = _read_json(self.budget_path, {})
        key = now_iso()[:10]
        state[key] = int(state.get(key, 0)) + tokens
        _write_json(self.budget_path, state)

    def _alert_once(self, key: str, subject: str, body: str, level: str = "warning") -> None:
        ctrl = _read_json(self.alerts_path, {})
        day = now_iso()[:10]
        sent = ctrl.get(day, [])
        if key in sent:
            return
        send_alert(self.cfg, subject, body, level=level)
        sent.append(key)
        ctrl[day] = sent
        _write_json(self.alerts_path, ctrl)

    # ------------- run once -------------
    def telemetry(self) -> Dict[str, Any]:
        return {"last_tick_at": self.last_tick_at, "last_tick_ok": self.last_tick_ok,
                "last_tick_err": self.last_tick_err}

    def run_once(self) -> Dict[str, Any]:
        self.last_tick_at = now_iso()
        self.last_tick_ok = True
        self.last_tick_err = ""
        counts = self.compliance.counts_today()
        budget_left = max(0, self.budget_days - self._today_budget())
        day_left = self.compliance.remaining_day(counts["sent_today"])
        hour_left = self.compliance.remaining_hour()
        allowed = max(0, min(day_left, hour_left, budget_left // max(1, int(self.cfg.yaml.get("models", {}).get("max_tokens_draft", 900)))))

        if not self.gate_open and not self.cfg.dry_run:
            self._alert_once("gate_required", "Approval gate still closed",
                             "Flip the gate open to let the recruiter send cohort 1. "
                             "Review pending drafts in the audit log first.")
            return {"sent": 0, "drafted": 0, "gate_open": False, "candidates_allowed": 0, "why": "gate_closed"}

        candidates = self.prospects.candidates(max(1, allowed)) if allowed > 0 else []
        summary: Dict[str, Any] = {
            "candidates_picked": len(candidates),
            "allowed_by_caps": allowed,
            "sent": 0,
            "drafted": 0,
            "hard_blocked": 0,
            "send_failed": 0,
            "gate_open": self.gate_open,
            "dry_run": self.cfg.dry_run,
            "budget_left": budget_left,
            "counts": counts,
        }

        for p in candidates:
            draft = draft_invite(self.cfg, self.compliance, p, channel=p.channel, llm=self.llm) if self.llm else draft_invite(self.cfg, self.compliance, p, channel=p.channel)
            if not draft.get("ok"):
                self.prospects.mark(p, "failed" if p.attempts + 1 >= 2 else "new", p.attempts + 1,
                                    next_ok_at=time.time() + int(self.cfg.yaml.get("channel", {}).get(p.channel, {}).get("min_interval_hours", 24)) * 3600)
                self.audit.append({"event": "hard_block", "email": p.email, "why": draft.get("why"),
                                   "issues": draft.get("issues", []), "at": now_iso()})
                summary["hard_blocked"] += 1
                continue

            self._add_budget(int(draft.get("token_est", 0)))
            self.prospects.mark(p, "pending", p.attempts, next_ok_at=None)
            self.audit.append({"event": "draft", "email": p.email, "name": p.name, "subject": draft["subject"],
                               "body": draft["body"][:1400], "issues": draft.get("issues", []),
                               "attempts": draft.get("attempts"), "at": now_iso()})
            summary["drafted"] += 1

            if self.cfg.dry_run:
                self.audit.append({"event": "dry_run_skip", "email": p.email, "subject": draft["subject"], "at": now_iso()})
                continue

            result = self.senders.dispatch(prospect=p, subject=draft["subject"], body=draft["body"])
            if result.get("ok") or "id" in result:
                self.compliance.record_send(p.email)
                self.prospects.mark(p, "sent", p.attempts + 1,
                                    next_ok_at=time.time() + int(self.cfg.yaml.get("channel", {}).get(p.channel, {}).get("min_interval_hours", 24)) * 3600)
                self.audit.append({"event": "sent", "email": p.email, "subject": draft["subject"],
                                   "provider": result.get("id", "n/a"), "at": now_iso()})
                summary["sent"] += 1
            else:
                self.prospects.mark(p, "new", p.attempts + 1,
                                    next_ok_at=time.time() + int(self.cfg.yaml.get("channel", {}).get(p.channel, {}).get("min_interval_hours", 24)) * 3600)
                self.audit.append({"event": "send_failed", "email": p.email, "detail": str(result.get("detail", ""))[:300], "at": now_iso()})
                summary["send_failed"] += 1

        counts = self.compliance.counts_today()
        summary["counts"] = counts
        summary["budget_left"] = max(0, self.budget_days - self._today_budget())

        if counts["bounces_today"] >= int(self.cfg.yaml.get("escalations", {}).get("bounce_burst_threshold", 5)):
            self._alert_once("bounce_burst", f"{counts['bounces_today']} bounces today — check the list",
                             "Hard bounces have been auto-opted-out. Review the source list quality.", "warning")
        if counts["optouts_today"] >= int(self.cfg.yaml.get("escalations", {}).get("optout_burst_threshold", 5)):
            self._alert_once("optout_burst", f"{counts['optouts_today']} opt-outs today",
                             "Review whether the invite tone or frequency needs tuning.", "warning")
        if self._today_budget() >= self.budget_days:
            self._alert_once("budget_exceeded", "Daily token budget reached — pausing for today",
                             "Will resume tomorrow, or raise budget_tokens_per_day.", "warning")
        return summary

    async def loop_forever(self) -> None:
        while True:
            try:
                summary = await asyncio.to_thread(self.run_once)
                log.info("recruiter tick: %s", summary)
            except Exception as e:  # noqa: BLE001
                self.last_tick_at = now_iso()
                self.last_tick_ok = False
                self.last_tick_err = f"{type(e).__name__}: {e}"
                log.exception("recruiter tick failed")
                self._alert_once(f"exception_{now_iso()[:10]}", "Recruiter tick crashed",
                                 f"{type(e).__name__}: {e}", "critical")
            await asyncio.sleep(max(30, self.cfg.heartbeat_sec))


def main() -> None:
    import argparse

    from .config import load_config

    parser = argparse.ArgumentParser(prog="recruiter")
    parser.add_argument("--once", action="store_true", help="run a single tick and exit")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)
    cfg = load_config()
    worker = Recruiter(cfg)
    if args.once:
        print(json.dumps(worker.run_once(), indent=2))
        return
    asyncio.run(worker.loop_forever())


if __name__ == "__main__":
    main()