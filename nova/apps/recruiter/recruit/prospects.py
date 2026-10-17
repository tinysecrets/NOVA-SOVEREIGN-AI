"""Prospect intake and state.

Sources are the Boss's own opted-in contacts (consent-list only), never scraped.
CSV columns: email, first_name (optional), consent (true/false, default true),
source (optional). Lines without consent are skipped and logged.
"""
from __future__ import annotations

import csv
import hashlib
import json
import re
import time
from dataclasses import dataclass, field
from io import StringIO
from pathlib import Path
from typing import Dict, List, Optional

from .compliance import Compliance
from .config import RecruiterConfig
from .store import JsonlStore, now_iso

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _email_key(email: str) -> str:
    return email.strip().lower()


@dataclass
class Prospect:
    email: str
    name: str
    consent: bool
    source: str
    status: str = "new"
    channel: str = "email"
    attempts: int = 0
    last_attempt_at: Optional[float] = None
    next_ok_at: Optional[float] = None
    ref: str = ""
    created_at: str = field(default_factory=now_iso)
    updated_at: str = field(default_factory=now_iso)

    def as_dict(self) -> Dict[str, object]:
        return {
            "email": self.email,
            "name": self.name,
            "consent": self.consent,
            "source": self.source,
            "status": self.status,
            "channel": self.channel,
            "attempts": self.attempts,
            "last_attempt_at": self.last_attempt_at,
            "next_ok_at": self.next_ok_at,
            "ref": self.ref,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }

    @classmethod
    def from_row(cls, row: Dict[str, object]) -> "Prospect":
        email = str(row.get("email", "")).strip()
        return cls(
            email=email,
            name=str(row.get("name") or row.get("first_name") or "").strip(),
            consent=bool(row.get("consent", True)),
            source=str(row.get("source") or "").strip(),
            channel=str(row.get("channel") or "email").strip(),
            status=str(row.get("status") or "new").strip(),
            attempts=int(row.get("attempts") or 0),
            last_attempt_at=row.get("last_attempt_at"),
            next_ok_at=row.get("next_ok_at"),
            ref=str(row.get("ref") or "").strip(),
        )


class ProspectStore:
    def __init__(self, cfg: RecruiterConfig, compliance: Compliance):
        self.cfg = cfg
        self.compliance = compliance
        self.store = JsonlStore(cfg.data_dir / "prospects.jsonl")

    def upsert(self, p: Prospect) -> None:
        key = _email_key(p.email)
        rows = self.store.all()
        kept: List[Dict[str, object]] = []
        for r in rows:
            if _email_key(str(r.get("email", ""))) == key:
                old = Prospect.from_row(r)
                p.created_at = old.created_at
                continue
            kept.append(r)
        kept.append(p.as_dict())
        self.store.clear()
        for r in kept:
            self.store.append(r)

    def ingest_csv(self, text: str) -> Dict[str, int]:
        reader = csv.DictReader(StringIO(text))
        added = 0
        dupes = 0
        skipped = 0
        bad = 0
        for raw in reader:
            email = str(raw.get("email") or "").strip()
            if not EMAIL_RE.match(email):
                bad += 1
                continue
            consent_raw = str(raw.get("consent") or "true").strip().lower()
            consent = consent_raw in {"1", "true", "yes", "y"}
            if not consent:
                skipped += 1
                continue
            if self.compliance.is_opted_out(email):
                skipped += 1
                continue
            existing = [r for r in self.store.rows() if _email_key(str(r.get("email", ""))) == _email_key(email)]
            if existing:
                dupes += 1
                continue
            self.upsert(Prospect.from_row(dict(raw)))
            added += 1
        return {"added": added, "dupes": dupes, "skipped": skipped, "bad": bad}

    def candidates(self, n: int = 20) -> List[Prospect]:
        now = time.time()
        out: List[Prospect] = []
        for r in self.store.rows():
            p = Prospect.from_row(r)
            if p.consent is False:
                continue
            if self.compliance.is_opted_out(p.email):
                continue
            if p.status in {"sent", "done"}:
                continue
            max_attempts = int(self.cfg.yaml.get("channel", {}).get(p.channel, {}).get("max_attempts", 2))
            if p.attempts >= max_attempts:
                continue
            min_gap = int(self.cfg.yaml.get("channel", {}).get(p.channel, {}).get("min_interval_hours", 24)) * 3600
            if p.next_ok_at and now < float(p.next_ok_at):
                continue
            if p.last_attempt_at and now - float(p.last_attempt_at) < min_gap:
                continue
            out.append(p)
            if len(out) >= n:
                break
        return out

    def mark(self, p: Prospect, status: str, attempts: int, next_ok_at: Optional[float] = None) -> None:
        target = _email_key(p.email)
        rows = self.store.all()
        kept: List[Dict[str, object]] = []
        for r in rows:
            if _email_key(str(r.get("email", ""))) == target:
                r["status"] = status
                r["attempts"] = attempts
                r["updated_at"] = now_iso()
                if next_ok_at is not None:
                    r["next_ok_at"] = next_ok_at
                r["last_attempt_at"] = time.time()
            kept.append(r)
        self.store.clear()
        for r in kept:
            self.store.append(r)

    def all(self) -> List[Prospect]:
        return [Prospect.from_row(r) for r in self.store.rows()]

    def stats(self) -> Dict[str, int]:
        rows = list(self.store.rows())
        return {
            "total": len(rows),
            "new": sum(1 for r in rows if r.get("status") in {"new", ""}),
            "pending": sum(1 for r in rows if r.get("status") == "pending"),
            "sent": sum(1 for r in rows if r.get("status") in {"sent", "done"}),
            "opted_out": sum(1 for r in self.compliance.optouts.rows() if r.get("contact")),
        }

    @staticmethod
    def ref_for(email: str) -> str:
        return hashlib.sha1(email.strip().lower().encode()).hexdigest()[:8]