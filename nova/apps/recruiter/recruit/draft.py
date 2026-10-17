"""Copy pipeline (in-hierarchy): write -> qa -> repair -> report.

The writer drafts a personalized invite, the QA agent (LLM soft pass + hard
compliance rules) reviews it, a repair pass fixes fixable issues, and the report
step yields the final payload. Hard violations are never sent.
"""
from __future__ import annotations

import json
from typing import Callable, Dict, List

from .compliance import Compliance
from .config import RecruiterConfig
from .llm import chat, parse_json_block


def _brain_kwargs(cfg: RecruiterConfig, max_tokens: int, temperature: float | None = None) -> Dict[str, object]:
    """Kwargs for the active brain only — the other providers stay unarmed."""
    kw: Dict[str, object] = {"max_tokens": max_tokens}
    if temperature is not None:
        kw["temperature"] = temperature
    provider = cfg.brain["provider"]
    if provider == "openrouter":
        kw.update(api_key=cfg.openrouter_api_key, base=cfg.openrouter_base)
    elif provider == "ollama_cloud":
        kw.update(ollama_base=cfg.ollama_cloud_base, ollama_model=cfg.ollama_cloud_model,
                  ollama_api_key=cfg.ollama_api_key)
    else:
        kw.update(ollama_base=cfg.ollama_base, ollama_model=cfg.ollama_model)
    return kw


def _writer_system(cfg: RecruiterConfig) -> str:
    tone = cfg.yaml.get("copy", {}).get("tone", "friendly, honest.")
    banned = cfg.banned_patterns
    lines = [
        "You are Ember, an honest AI companion who helps the Wah-Lah team invite its own "
        "consenting contacts. You write calm, personal, non-pushy invitation copy for the "
        "wah-lah.com sweepstakes-style platform (free to enter, no purchase necessary).\n",
        f"Tone: {tone}",
    ]
    if banned:
        lines.append(
            "Never use any of these phrases, even to negate them: " + "; ".join(banned) + "."
        )
    lines += [
        "Rules:",
        "- One clear call to action linking to the app URL.",
        "- Never promise winnings, never create urgency, never ask for payment, "
        "never imply reward for sharing.",
        "- Must mention wah-lah by name.",
        "- Include one honest closing line that this invite was drafted by an AI assistant (Ember).",
        '- Output ONLY a JSON object: {"subject": "...", "body": "..."}. '
        "Body is plain text with the final CTA on its own line.",
    ]
    return "\n".join(lines)


def _writer_user(cfg: RecruiterConfig, prospect, channel: str) -> str:
    parts = [f"Prospect first name: {prospect.name or 'friend'}", f"Channel: {channel}"]
    if prospect.source:
        parts.append(f"Context they came from: {prospect.source}")
    cta = f"{cfg.url_app}?ref={prospect.ref or 'wah-lah'}"
    parts.append(f"CTA link: {cta}")
    parts.append(f"Home link: {cfg.url_home}")
    if cfg.socials:
        parts.append("Official socials: " + ", ".join(cfg.socials))
    parts.append("First line must use their name naturally, never 'Dear sir/madam'.")
    return "\n".join(parts)


def _qa_system(cfg: RecruiterConfig) -> str:
    return (
        "You are the QA agent. Review invitation copy for legality, safety and platform rules.\n"
        "Flag: any promise of winnings or prize, urgency or pressure, requests for payment, "
        "spam patterns, deception, unprofessional tone.\n"
        'Output ONLY JSON: {"issues": ["..."], "acceptable": true|false}'
    )


def _repo(cfg: RecruiterConfig) -> str:
    return (
        "Rewrite the copy to fix every issue the QA agent raised. Keep the name and CTA. "
        'Output ONLY JSON: {"subject": "...", "body": "..."}'
    )


def draft_invite(
    cfg: RecruiterConfig,
    compliance: Compliance,
    prospect,
    channel: str = "email",
    *,
    llm: Callable = chat,
) -> Dict[str, object]:
    model = cfg.model_for(high=False)
    writer = llm(
        model,
        _writer_system(cfg),
        _writer_user(cfg, prospect, channel),
        **_brain_kwargs(cfg, int(cfg.yaml.get("models", {}).get("max_tokens_draft", 900))),
    )
    block = parse_json_block(writer)
    subject = str(block.get("subject") or "").strip()
    body = str(block.get("body") or "").strip()
    if not body:
        return {"ok": False, "why": "writer_produced_no_copy", "raw": writer[:400]}

    verdict = compliance.qa_verdict(subject, body)
    if str(verdict["verdict"]) == "FAIL":
        return {"ok": False, "why": "hard_block", "subject": subject, "body": body,
                "issues": verdict["issues"]}

    soft = llm(
        cfg.model_for(high=False),
        _qa_system(cfg),
        f"Subject: {subject}\nBody:\n{body}",
        **_brain_kwargs(cfg, int(cfg.yaml.get("models", {}).get("max_tokens_qa", 600)), temperature=0.2),
    )
    qa = parse_json_block(soft)
    issues: List[str] = list(verdict["issues"])
    if str(qa.get("acceptable", "true")).strip().lower() in {"false", "no", "0"}:
        for i in qa.get("issues", []):
            issues.append(f"qa_soft: {i}")

    attempts = 1
    if "qa_soft:" in str(issues) or any(i.startswith(("banned", "missing_", "subject_too_long", "body_too_long")) for i in issues):
        attempt = 2
        while attempt <= 2 and issues and not any(i.startswith("banned") for i in issues):
            fixed = llm(
                cfg.model_for(high=False),
                _writer_system(cfg),
                _writer_user(cfg, prospect, channel) + "\n\nQA concerns to fix:\n" + "\n".join(issues) + "\n\n" + _repo(cfg),
                **_brain_kwargs(cfg, int(cfg.yaml.get("models", {}).get("max_tokens_draft", 900))),
            )
            block = parse_json_block(fixed)
            subject = str(block.get("subject") or subject).strip()
            body = str(block.get("body") or body).strip()
            verdict = compliance.qa_verdict(subject, body)
            issues = list(verdict["issues"])
            if str(verdict["verdict"]) == "FAIL":
                return {"ok": False, "why": "hard_block_after_repair", "subject": subject,
                        "body": body, "issues": issues}
            soft2 = llm(
                cfg.model_for(high=False),
                _qa_system(cfg),
                f"Subject: {subject}\nBody:\n{body}",
                **_brain_kwargs(cfg, int(cfg.yaml.get("models", {}).get("max_tokens_qa", 600)), temperature=0.2),
            )
            qa2 = parse_json_block(soft2)
            if str(qa2.get("acceptable", "true")).strip().lower() in {"false", "no", "0"}:
                issues += [f"qa_soft: {i}" for i in qa2.get("issues", []) if f"qa_soft: {i}" not in issues]
            attempts = attempt
            if not issues:
                break
            attempt += 1

    issues = [i for i in issues if not i.startswith("banned")]
    return {
        "ok": True,
        "subject": subject,
        "body": body,
        "issues": issues,
        "attempts": attempts,
        "token_est": len(subject) // 4 + len(body) // 4,
    }