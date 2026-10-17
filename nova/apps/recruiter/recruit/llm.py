"""Model calls for the recruiter (Hermes combo via OpenRouter, Ollama fallback)."""
from __future__ import annotations

import json
import urllib.request
from typing import Dict, List


def chat(
    model: str,
    system: str,
    user: str,
    *,
    max_tokens: int = 900,
    temperature: float = 0.6,
    api_key: str = "",
    base: str = "https://openrouter.ai/api/v1",
    ollama_base: str = "",
    ollama_model: str = "",
    ollama_api_key: str = "",
) -> str:
    if api_key:
        return _openrouter(model, system, user, max_tokens, temperature, api_key, base)
    if ollama_base:
        return _ollama(ollama_model, system, user, ollama_base, max_tokens, auth=ollama_api_key)
    return ""


def _openrouter(model, system, user, max_tokens, temperature, api_key, base) -> str:
    url = f"{base.rstrip('/')}/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": max_tokens,
        "temperature": temperature,
    }
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {api_key}")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode())
        return data["choices"][0]["message"]["content"] or ""
    except Exception:  # noqa: BLE001
        return ""


def _ollama(model, system, user, base, max_tokens, auth="") -> str:
    url = f"{base.rstrip('/')}/api/chat"
    payload: Dict[str, object] = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
    }
    if auth == "":
        # Local only: cap generation length. Cloud (reasoning models like
        # gpt-oss) counts thinking tokens against num_predict — omitting it
        # prevents the model from starving its visible content.
        payload["options"] = {"num_predict": max_tokens}
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    if auth:
        req.add_header("Authorization", f"Bearer {auth}")
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            data = json.loads(resp.read().decode())
        return data.get("message", {}).get("content") or ""
    except Exception:  # noqa: BLE001
        return ""


def parse_json_block(text: str) -> Dict[str, object]:
    if not text:
        return {}
    try:
        return json.loads(text)
    except Exception:  # noqa: BLE001
        import re

        m = re.search(r"\{[\s\S]*\}", text)
        if m:
            try:
                return json.loads(m.group(0))
            except Exception:  # noqa: BLE001
                return {}
        return {}


def token_count(text: str) -> int:
    return max(1, len(text) // 4)