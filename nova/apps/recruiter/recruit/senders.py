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
from html import escape
from urllib.parse import urlencode, urlsplit
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
    if len(secret) < 32:
        raise ValueError("UNSUBSCRIBE_SECRET must contain at least 32 characters")
    return hmac.new(secret.encode(), email.strip().lower().encode(), hashlib.sha256).hexdigest()[:32]


def verify_unsubscribe_token(email: str, token: str, secret: str) -> bool:
    if not email or not token or len(secret) < 32:
        return False
    try:
        expected = unsubscribe_token(email, secret)
    except ValueError:
        return False
    return hmac.compare_digest(expected, token)


class Senders:
    def __init__(self, cfg: RecruiterConfig):
        self.cfg = cfg

    def _unsubscribe_url(self, to_email: str) -> str:
        base = self.cfg.env.get("UNSUBSCRIBE_BASE_URL", "").strip().rstrip("/")
        secret = self.cfg.env.get("UNSUBSCRIBE_SECRET", "")
        if not base or len(secret) < 32:
            return ""
        parsed = urlsplit(base)
        if parsed.scheme != "https" or not parsed.netloc:
            return ""
        token = unsubscribe_token(to_email, secret)
        query = urlencode({"email": to_email, "t": token})
        return f"{base}/api/recruiter/unsubscribe?{query}"

    def _footer(self, to_email: str, channel: str) -> str:
        parts: List[str] = []
        note = str(self.cfg.yaml.get("compliance", {}).get("sweepstakes_note", ""))
        if note:
            parts.append(escape(note))
        if str(self.cfg.yaml.get("copy", {}).get("ai_disclosure", True)).lower() in {"true", "1", "yes"}:
            parts.append("Drafted with help from an AI assistant (Ember).")
        if channel == "email":
            url = self._unsubscribe_url(to_email)
            if url:
                parts.append(f'<a href="{escape(url, quote=True)}">Unsubscribe</a>')
            else:
                mailto = f"mailto:{self.cfg.bot_email}?subject=UNSUBSCRIBE"
                parts.append(f'<a href="{escape(mailto, quote=True)}">Unsubscribe</a>')
            if self.cfg.postal_address:
                parts.append(escape(self.cfg.postal_address))
        href = "https://wah-lah.com"
        return "<br><br>—<br>" + "<br>".join(parts + [f'<a href="{href}">wah-lah.com</a>'])

    def send_email(self, *, to: str, subject: str, body: str) -> Dict[str, Any]:
        if not self.cfg.resend_api_key:
            return {"ok": False, "detail": "RESEND_API_KEY not configured"}
        if not self.cfg.postal_address.strip():
            return {"ok": False, "detail": "POSTAL_ADDRESS required before live email (CAN-SPAM)"}
        compliance_cfg = self.cfg.yaml.get("compliance", {})
        unsubscribe_url = self._unsubscribe_url(to)
        if compliance_cfg.get("add_list_unsubscribe", True) and not unsubscribe_url:
            return {"ok": False, "detail": "A public HTTPS UNSUBSCRIBE_BASE_URL and a 32+ character UNSUBSCRIBE_SECRET are required before live email"}

        html = escape(body).replace("\n", "<br>") + self._footer(to, "email")
        text_parts = [body, "", "---", str(compliance_cfg.get("sweepstakes_note", "")),
                      "Drafted with help from an AI assistant (Ember)."]
        if unsubscribe_url:
            text_parts.append(f"Unsubscribe: {unsubscribe_url}")
        else:
            text_parts.append(f"Unsubscribe: mailto:{self.cfg.bot_email}?subject=UNSUBSCRIBE")
        text_parts.append(self.cfg.postal_address)
        text_parts.append("https://wah-lah.com")
        payload: Dict[str, Any] = {
            "from": f"{self.cfg.bot_name} <{self.cfg.bot_email}>",
            "to": [to],
            "reply_to": self.cfg.bot_email,
            "subject": subject[:140],
            "html": html,
            "text": "\n".join(part for part in text_parts if part is not None),
        }
        if unsubscribe_url and compliance_cfg.get("add_list_unsubscribe", True):
            payload["headers"] = {
                "List-Unsubscribe": f"<{unsubscribe_url}>, <mailto:{self.cfg.bot_email}?subject=UNSUBSCRIBE>",
                "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
            }
        return _post_json("https://api.resend.com/emails", payload, self.cfg.resend_api_key)

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