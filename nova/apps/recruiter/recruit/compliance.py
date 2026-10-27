"""Compliance rails: content filter, opt-outs, rate limiting, audit log.

Keeps the worker legal and platform-rule-safe:
  - hard-blocks illegal / scammy / spam phrasing (CAN-SPAM, gambling exposure)
  - records every opt-out and honors it instantly
  - enforces per-hour and per-day send ceilings
  - audits every send / flag / digest event to JSONL
"""
from __future__ import annotations

import re
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from .config import RecruiterConfig
from .store import JsonlStore, now_iso


@dataclass
class Compliance:
    cfg: RecruiterConfig
    optouts: JsonlStore
    bounces: JsonlStore
    rate: JsonlStore
    audit: JsonlStore
    _hour_window: Optional[float] = field(default=None, repr=False)

    def __init__(self, cfg: RecruiterConfig):
        self.cfg = cfg
        d = cfg.data_dir
        self.optouts = JsonlStore(d / "optouts.jsonl")
        self.bounces = JsonlStore(d / "bounces.jsonl")
        self.rate = JsonlStore(d / "rate.jsonl")
        self.audit = JsonlStore(d / "audit.jsonl")

    # ---------------- content filter ----------------
    def _find(self, text: str, patterns: List[str]) -> List[str]:
        hits: List[str] = []
        for pat in patterns:
            try:
                if re.search(re.escape(pat), text, re.IGNORECASE):
                    hits.append(pat)
            except re.error:
                continue
        return hits

    def copy_issues(self, subject: str, body: str) -> List[str]:
        issues = []
        issues += [f"banned_subject: {p}" for p in self._find(subject, self.cfg.banned_subject_patterns)]
        issues += [f"banned: {p}" for p in self._find(body, self.cfg.banned_patterns)]
        if len(subject) > int(self.cfg.yaml.get("copy", {}).get("subject_max", 70)):
            issues.append("subject_too_long")
        if len(body) > int(self.cfg.yaml.get("copy", {}).get("body_max_chars", 900)):
            issues.append("body_too_long")
        if "http://" in body:
            issues.append("plain_http_link")
        mandatory = ["wah-lah"]
        if not any(m in body.lower() for m in mandatory):
            issues.append("missing_wah_lah_reference")
        disclosure = str(self.cfg.yaml.get("copy", {}).get("ai_disclosure", True))
        if disclosure.lower() in {"true", "1", "yes"} and "ai" not in (subject + body).lower():
            issues.append("missing_ai_disclosure")
        return issues

    def qa_verdict(self, subject: str, body: str) -> Dict[str, object]:
        issues = self.copy_issues(subject, body)
        p0 = [i for i in issues if i.startswith("banned")]
        return {"verdict": "FAIL" if p0 else ("PASS" if not issues else "ISSUES"), "issues": issues}

    # ---------------- opt-out ----------------
    def is_opted_out(self, contact: str) -> bool:
        key = self._key(contact)
        return any(r.get("contact") == key for r in self.optouts.rows())

    def opt_out(self, contact: str, reason: str = "") -> None:
        key = self._key(contact)
        if not any(r.get("contact") == key for r in self.optouts.rows()):
            self.optouts.append({"contact": key, "reason": reason, "at": now_iso()})
            self.audit.append({"event": "optout", "contact": key, "reason": reason, "at": now_iso()})

    def record_bounce(self, contact: str, detail: str = "") -> None:
        self.bounces.append({"contact": self._key(contact), "detail": detail, "at": now_iso()})
        self.opt_out(contact, reason="bounce")

    @staticmethod
    def _key(contact: str) -> str:
        return contact.strip().lower()

    # ---------------- rate limiting ----------------
    def remaining_hour(self) -> int:
        cap = self.cfg.max_per_hour
        now = time.time()
        recent = sum(1 for r in self.rate.rows() if isinstance(r.get("at"), (int, float)) and now - float(r["at"]) < 3600)
        return max(0, cap - recent)

    def remaining_day(self, sent_today: int) -> int:
        return max(0, self.cfg.daily_cap - sent_today)

    def record_send(self, contact: str) -> None:
        self.rate.append({"contact": self._key(contact), "at": time.time()})

    # ---------------- audit ----------------
    def log(self, event: str, **fields: object) -> None:
        rec = {"event": event, "at": now_iso()}
        rec.update(fields)
        self.audit.append(rec)

    # ---------------- counters ----------------
    def counts_today(self) -> Dict[str, int]:
        today = now_iso()[:10]
        rows = self.rate.all()
        sent_24h = sum(1 for r in rows if isinstance(r.get("at"), (int, float)) and time.time() - float(r["at"]) < 86400)
        optouts_today = sum(1 for r in self.optouts.rows() if str(r.get("at", ""))[:10] == today)
        bounces_today = sum(1 for r in self.bounces.rows() if str(r.get("at", ""))[:10] == today)
        return {"sent_today": sent_24h, "sent": len(rows), "optouts_today": optouts_today, "bounces_today": bounces_today}