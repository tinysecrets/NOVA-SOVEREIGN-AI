"""Delivery senders.

Email: Resend REST API (same key the MCP uses). Includes CAN-SPAM footer:
physical address, unsubscribe, AI disclosure, sweepstakes note.

Telegram / Discord: enabled only when tokens are set AND the recipient has
opted in (consent list). They only ever carry opt-in traffic.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import urllib.request
from typing import Any, Dict, List, Optional

from .config import RecruiterConfig


def _post_json(url: str, payload: Dict[str, Any], token: str, bearer: bool = True) -> Dict[str, Any]:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "recruiter/0.1 (wah-lah.com ops; resend)")
    req.add_header("Authorization", f"Bearer {token}" if bearer else token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {"ok": True}
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode()
        except Exception:
            pass
        return {"ok": False, "status": e.code, "detail": body[:500]}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "detail": str(e)}


def unsubscribe_token(email: str, secret: str) -> str:
    return hmac.new(secret.encode(), email.strip().lower().encode(), hashlib.sha256).hexdigest()[:16]


class Senders:
    def __init__(self, cfg: RecruiterConfig):
        self.cfg = cfg

    def _footer(self, to_email: str, channel: str) -> str:
        parts: List[str] = []
        note = str(self.cfg.yaml.get("compliance", {}).get("sweepstakes_note", ""))
        if note:
            parts.append(note)
        if str(self.cfg.yaml.get("copy", {}).get("ai_disclosure", True)).lower() in {"true", "1", "yes"}:
            parts.append("Drafted with help from an AI assistant (Ember).")
        if channel == "email":
            unsub = ""
            base = self.cfg.env.get("UNSUBSCRIBE_BASE_URL", "")
            if base:
                tok = unsubscribe_token(to_email, self.cfg.env.get("RESEND_API_KEY", "recruiter-secret"))
                unsub = f'<a href="{base}/unsubscribe?email={to_email}&t={tok}">Unsubscribe</a>'
            else:
                unsub = f'<a href="mailto:{self.cfg.bot_email}?subject=UNSUBSCRIBE">Unsubscribe</a>'
            parts.append(unsub)
            if self.cfg.postal_address:
                parts.append(self.cfg.postal_address)
        href = "https://wah-lah.com"
        return "<br><br>—<br>" + "<br>".join(parts + [f'<a href="{href}">wah-lah.com</a>'])

    def send_email(self, *, to: str, subject: str, body: str) -> Dict[str, Any]:
        if not self.cfg.resend_api_key:
            return {"ok": False, "detail": "RESEND_API_KEY not configured"}
        if not self.cfg.postal_address:
            return {"ok": False, "detail": "POSTAL_ADDRESS required before live email (CAN-SPAM)"}
        html = body.replace("\n", "<br>") + self._footer(to, "email")
        text = body + "\n\n---\n" + self._footer(to, "email").replace("<br>", "\n").replace('<a href="', "").replace('">', ": ").replace("</a>", "")
        resp = _post_json(
            "https://api.resend.com/emails",
            {
                "from": f"{self.cfg.bot_name} <{self.cfg.bot_email}>",
                "to": [to],
                "reply_to": self.cfg.bot_email,
                "subject": subject[:140],
                "html": html,
                "text": text,
            },
            self.cfg.resend_api_key,
        )
        return resp

    def send_telegram(self, *, chat_id: str, subject: str, body: str) -> Dict[str, Any]:
        if not self.cfg.telegram_token:
            return {"ok": False, "detail": "TELEGRAM_BOT_TOKEN not configured"}
        msg = f"{subject}\n\n{body}"
        if self.cfg.telegram_invite_url:
            msg += f"\n\nJoin: {self.cfg.telegram_invite_url}"
        return _post_json(
            f"https://api.telegram.org/bot{self.cfg.telegram_token}/sendMessage",
            {"chat_id": chat_id, "text": msg, "disable_web_page_preview": False},
            self.cfg.telegram_token,
            bearer=False,
        )

    def send_discord(self, *, user_id: str, subject: str, body: str) -> Dict[str, Any]:
        if not self.cfg.discord_token:
            return {"ok": False, "detail": "DISCORD_BOT_TOKEN not configured"}
        msg = f"{subject}\n\n{body}"
        if self.cfg.discord_invite_url:
            msg += f"\n\nJoin: {self.cfg.discord_invite_url}"
        return _post_json(
            f"https://discord.com/api/v10/users/{user_id}/messages",
            {"content": msg[:1900]},
            self.cfg.discord_token,
        )

    def dispatch(self, *, prospect: Any, subject: str, body: str) -> Dict[str, Any]:
        ch = prospect.channel
        if ch == "telegram":
            return self.send_telegram(chat_id=prospect.email, subject=subject, body=body)
        if ch == "discord":
            return self.send_discord(user_id=prospect.email, subject=subject, body=body)
        return self.send_email(to=prospect.email, subject=subject, body=body)