"""Escalations up the hierarchy — email the Boss only when truly needed."""
from __future__ import annotations

import json
import urllib.request

from .config import RecruiterConfig

LEVELS = ("info", "warning", "critical")


def _post_json(url: str, payload: dict, token: str) -> dict:
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "recruiter/0.1 (wah-lah.com ops; resend)")
    req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {"ok": True}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "detail": str(e)}


def send_alert(cfg: RecruiterConfig, subject: str, body: str, level: str = "warning") -> dict:
    if level not in LEVELS:
        level = "warning"
    if not cfg.resend_api_key:
        return {"ok": False, "detail": "no RESEND_API_KEY", "subject": subject}
    ok = _post_json(
        "https://api.resend.com/emails",
        {
            "from": f"{cfg.bot_name} Recruiter <{cfg.bot_email}>",
            "to": [cfg.boss_email],
            "subject": f"[{level.upper()}] Recruiter: {subject}",
            "text": body,
        },
        cfg.resend_api_key,
    )
    return {**ok, "level": level}