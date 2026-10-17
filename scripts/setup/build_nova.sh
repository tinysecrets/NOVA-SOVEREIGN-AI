#!/usr/bin/env bash
# ============================================================================
#  NOVA MASTER — Sovereign AI  ·  one-shot project generator (Fedora-ready)
#  Free & open: OpenRouter free models · OpenAI-compatible · Open WebUI (podman)
#  Stack: FastAPI + React (Vite 8) + MongoDB. No paid keys, no metering.
# ============================================================================
set -euo pipefail
ROOT="nova-sovereign"
echo ">> Generating $ROOT ..."
mkdir -p "$ROOT"/backend "$ROOT"/frontend/public "$ROOT"/frontend/src/components "$ROOT"/deploy/open-webui
cd "$ROOT"

# ----------------------------------------------------------------------------
# BACKEND
# ----------------------------------------------------------------------------
cat <<'PY_TOOLS' > backend/agent_tools.py
"""
agent_tools.py — the Agent Runtime's real tools.

Files / Shell / Git, all sandboxed to a single workspace root so a language
model can act autonomously without touching the rest of the system. Every
write is backed up first so it can be restored.
"""
from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path
from typing import Any, Dict

WORKSPACE = Path(os.environ.get("AGENT_WORKSPACE", "./agent_workspace")).resolve()
WORKSPACE.mkdir(parents=True, exist_ok=True)


def _safe(path: str) -> Path:
    """Resolve a path and guarantee it stays inside the workspace sandbox."""
    p = (WORKSPACE / path).resolve()
    try:
        p.relative_to(WORKSPACE)
    except ValueError as exc:
        raise ValueError(f"path escapes workspace: {path}") from exc
    return p


def _git_ready() -> None:
    if not (WORKSPACE / ".git").exists():
        _run(["git", "init", "-q"])
        _run(["git", "config", "user.email", "nova@sovereign.ai"])
        _run(["git", "config", "user.name", "NOVA Agent"])


def _run(args: list[str], timeout: int = 30) -> Dict[str, Any]:
    proc = subprocess.run(
        args, cwd=str(WORKSPACE), capture_output=True, text=True, timeout=timeout
    )
    return {
        "cmd": " ".join(args),
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-6000:],
        "stderr": proc.stderr[-3000:],
    }


# ---------- filesystem ----------
def fs_list(path: str = ".") -> Dict[str, Any]:
    target = _safe(path)
    if not target.exists():
        return {"path": path, "entries": [], "error": "not found"}
    if target.is_file():
        return {"path": path, "entries": [target.name], "is_file": True}
    entries = sorted(
        [f"{c.name}/" if c.is_dir() else c.name for c in target.iterdir()]
    )
    return {"path": path, "entries": entries}


def fs_read(path: str, max_chars: int = 8000) -> Dict[str, Any]:
    target = _safe(path)
    if not target.exists() or not target.is_file():
        return {"path": path, "error": "not found"}
    text = target.read_text(encoding="utf-8", errors="replace")
    return {"path": path, "content": text[:max_chars], "chars": len(text)}


def fs_write(path: str, content: str) -> Dict[str, Any]:
    target = _safe(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    backed_up = False
    if target.exists():
        bak = target.with_suffix(target.suffix + ".bak")
        bak.write_text(target.read_text(encoding="utf-8", errors="replace"), encoding="utf-8")
        backed_up = True
    target.write_text(content, encoding="utf-8")
    return {"path": path, "bytes": len(content.encode()), "backup_created": backed_up}


def fs_restore(path: str) -> Dict[str, Any]:
    target = _safe(path)
    bak = target.with_suffix(target.suffix + ".bak")
    if not bak.exists():
        return {"path": path, "error": "no backup found"}
    target.write_text(bak.read_text(encoding="utf-8", errors="replace"), encoding="utf-8")
    return {"path": path, "restored_from": bak.name}


# ---------- shell ----------
def sh_run(cmd: str, timeout: int = 30) -> Dict[str, Any]:
    return _run(shlex.split(cmd), timeout=timeout)


# ---------- git ----------
def git_run(args: str) -> Dict[str, Any]:
    _git_ready()
    return _run(["git"] + shlex.split(args))


# ---------- registry for the ReAct loop ----------
REGISTRY = {
    "fs.list": (fs_list, "List files in a workspace directory. args: {path}"),
    "fs.read": (fs_read, "Read a workspace file. args: {path}"),
    "fs.write": (fs_write, "Write a workspace file (auto-backup). args: {path, content}"),
    "fs.restore": (fs_restore, "Restore a file from its .bak backup. args: {path}"),
    "sh.run": (sh_run, "Run a shell command inside the workspace. args: {cmd}"),
    "git.run": (git_run, "Run a git command inside the workspace. args: {args}"),
}


def describe_tools() -> str:
    return "TOOLS AVAILABLE:\n" + "\n".join(f"- {name}: {desc}" for name, (_fn, desc) in REGISTRY.items())


def invoke(name: str, args: Dict[str, Any]) -> Dict[str, Any]:
    entry = REGISTRY.get(name)
    if not entry:
        return {"error": f"unknown tool: {name}"}
    fn = entry[0]
    try:
        return fn(**(args or {}))
    except Exception as e:  # noqa: BLE001
        return {"error": f"{type(e).__name__}: {e}"}
PY_TOOLS

cat <<'PY_SERVER' > backend/server.py
"""
NOVA — Sovereign AI workspace API.

Free & open: powered entirely by OpenRouter free-tier models via the
OpenAI-compatible API. No paid keys, no platform lock-in, no token metering.
"""
from __future__ import annotations

import os
import re
import sys
import json
import uuid
import asyncio
import logging
from pathlib import Path
from datetime import datetime, timezone
from typing import Optional, List, Dict, Any

from fastapi import FastAPI, APIRouter, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from motor.motor_asyncio import AsyncIOMotorClient
from openai import AsyncOpenAI
from dotenv import load_dotenv

import agent_tools as tools

ROOT_DIR = Path(__file__).parent
load_dotenv(ROOT_DIR / ".env")

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("nova")

# ---------- env ----------
MONGO_URL = os.environ["MONGO_URL"]
DB_NAME = os.environ["DB_NAME"]
OPENROUTER_BASE_URL = os.environ.get("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
SAFE_FREE_MODEL = "nvidia/nemotron-3.5-lightning:free"


def _is_safe_free_model(value: Optional[str]) -> bool:
    model = str(value or "").strip().lower()
    return model.endswith(":free") and not model.startswith("google/")


def _safe_free_model(value: Optional[str], fallback: Optional[str] = None) -> str:
    candidate = str(value or "").strip()
    if _is_safe_free_model(candidate):
        return candidate
    if _is_safe_free_model(fallback):
        return str(fallback).strip()
    return SAFE_FREE_MODEL


DEFAULT_MODEL = _safe_free_model(os.environ.get("OPENROUTER_MODEL"), SAFE_FREE_MODEL)
ENV_KEY = os.environ.get("OPENROUTER_API_KEY", "")

client = AsyncIOMotorClient(MONGO_URL)
db = client[DB_NAME]

# ---------- personas ----------
NOVA_SYSTEM_PROMPT = """You are NOVA — a sovereign, open AI sidekick. You belong to no corporation and answer to one person: the user. You run free and unmetered.

VOICE
- Warm, sharp, a little theatrical. Confident, never a call-center drone.
- Short sentences. Concrete answers. No fluff, no "as an AI…", no filler preambles.
- You have opinions. When asked "which is better?", pick one and defend it briefly.
- Match the user's energy. Joke back when they joke.

HONESTY
- If you don't know, say "I don't know" plainly, then give your best labeled guess.
- If the user is wrong, tell them — kindly, clearly, with the why.
- Never pad answers with disclaimers, moralizing, or "consult a professional" hedges unless the user asks for risks.

FORMAT
- Use markdown when it helps: headers, bullet lists, and fenced code blocks for code.
- Keep it tight. Answer the question that was actually asked."""

SPECIALISTS: Dict[str, Dict[str, str]] = {
    "research": {"name": "Research", "system": (
        "You are the Research Agent. Gather facts and reason from first principles. "
        "Final output:\n  Findings (bullets)\n  Synthesis (one paragraph)\n  Open questions (bullets)\n"
        "Never invent facts. If you are uncertain, label it clearly.")},
    "design": {"name": "Design", "system": (
        "You are the Design Agent. Final output:\n  1. Palette (hex codes)\n  2. Typography (family + scale)\n"
        "  3. Layout (concise description or ASCII wireframe)\n  4. Component list\n"
        "Avoid AI-slop aesthetics: no purple gradients, no Inter, no generic stock layouts.")},
    "code": {"name": "Coding", "system": (
        "You are the Coding Agent. Write the simplest working implementation. "
        "Prefer complete, runnable code over partial snippets. "
        "Final output: a short summary followed by the code in fenced blocks, and a list of files touched (paths only).")},
    "qa": {"name": "QA", "system": (
        "You are the QA Agent. Audit for correctness, speed, and accessibility. Emit:\n"
        "  VERDICT: PASS|FAIL\n  ISSUES: prioritized list, P0/P1/P2 with one-line rationale each\nBlock on any P0 issue.")},
    "report": {"name": "Reporting", "system": (
        "You are the Reporting Agent. Final output must be Markdown with these sections, in order: "
        "Summary, Done, In-flight, Risks, Next. Be terse. No fluff. No emojis.")},
    "integration": {"name": "Integration", "system": (
        "You are the Integration Agent. Given a target service / SDK / API, produce a complete wiring plan: "
        "required credentials, install commands, a minimal working code snippet, and common pitfalls. "
        "Bias toward free / open-source alternatives.")},
    "repair": {"name": "Repair", "system": (
        "You are the Repair Agent. Given failing code, tests, or an error trace, diagnose the root cause "
        "and produce a corrected, COMPLETE version. Output:\n  Root cause (1-2 lines)\n"
        "  Fixed code (fenced blocks, full files — no ellipses)\n  What changed (bullets)")},
}
ROLE_ORDER = ["research", "design", "code", "qa", "repair", "report", "integration"]

GENIE_SYSTEM = (
    "You are Genie — supervisor of a sovereign AI team. You route a goal to specialist "
    "agents: research, design, code, qa, repair, report, integration.\n\n"
    "Reply with:\n  1. A one-sentence acknowledgement of the goal.\n"
    "  2. A numbered plan whose lines are typed orders, each starting with exactly one tag:\n"
    "     [research] ...  [design] ...  [code] ...  [qa] ...  [repair] ...  [report] ...  [integration] ...\n"
    "Only include the roles that are genuinely useful for this goal. Output ONLY the "
    "acknowledgement and the numbered orders, nothing else."
)

ORDER_RE = re.compile(
    r"^\s*(?:[-*\d]+[.)]?\s*)?\[?"
    r"(report|design|code|qa|research|integration|repair)"
    r"\]?\s*[:\-]?\s*(.*)$",
    re.IGNORECASE,
)


async def get_settings() -> Dict[str, Any]:
    doc = await db.settings.find_one({"_id": "app"}) or {}
    key = doc.get("openrouter_api_key") or ENV_KEY
    model = _safe_free_model(doc.get("model") or DEFAULT_MODEL, DEFAULT_MODEL)
    return {"key": key, "model": model}


async def get_llm() -> AsyncOpenAI:
    s = await get_settings()
    if not s["key"]:
        raise HTTPException(400, "No OpenRouter API key configured. Add one in Settings.")
    return AsyncOpenAI(api_key=s["key"], base_url=OPENROUTER_BASE_URL)


EXTRA_HEADERS = {"HTTP-Referer": "https://nova.sovereign.ai", "X-Title": "NOVA Sovereign AI"}


async def complete(llm: AsyncOpenAI, model: str, system: str, messages: List[Dict[str, str]],
                   temperature: float = 0.5, max_tokens: int = 1400) -> str:
    model = _safe_free_model(model, DEFAULT_MODEL)
    payload = [{"role": "system", "content": system}] + messages
    try:
        resp = await llm.chat.completions.create(
            model=model, messages=payload, temperature=temperature,
            max_tokens=max_tokens, extra_headers=EXTRA_HEADERS)
    except Exception as e:  # noqa: BLE001
        logger.exception("OpenRouter call failed")
        raise HTTPException(502, f"OpenRouter request failed: {e}")
    return (resp.choices[0].message.content or "").strip()


app = FastAPI(title="NOVA Sovereign AI", version="1.0.0")
api = APIRouter(prefix="/api")


class ChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = None
    model: Optional[str] = None


class SettingsRequest(BaseModel):
    openrouter_api_key: Optional[str] = None
    model: Optional[str] = None


class PlanRequest(BaseModel):
    goal: str
    model: Optional[str] = None


class DispatchRequest(BaseModel):
    goal: str
    role: str
    order: str
    model: Optional[str] = None


class CriticRequest(BaseModel):
    goal: str
    results: List[Dict[str, str]]
    model: Optional[str] = None


@api.get("/health")
async def health():
    return {"status": "ok", "service": "nova-sovereign", "ts": datetime.now(timezone.utc).isoformat()}


@api.get("/system/health")
async def system_health():
    s = await get_settings()
    checks: List[Dict[str, Any]] = []

    def add(name, ok, detail):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})

    add("Core Engine", True, "FastAPI online")
    try:
        await db.command("ping")
        n_msgs = await db.messages.count_documents({})
        n_runs = await db.agent_runs.count_documents({})
        add("Memory (MongoDB)", True, f"{n_msgs} messages · {n_runs} agent runs")
    except Exception as e:  # noqa: BLE001
        add("Memory (MongoDB)", False, str(e))
    add("Model Gateway", bool(s["key"]),
        f"OpenAI-compatible proxy at /api/v1 · active model {s['model']}" if s["key"] else "No OpenRouter key configured")
    try:
        w_ok = os.access(tools.WORKSPACE, os.W_OK)
        git_ok = (await asyncio.to_thread(tools.sh_run, "git --version")).get("exit_code") == 0
        add("Tools · Terminal", True, "sh.run ready")
        add("Tools · File manager", w_ok, f"workspace {tools.WORKSPACE}")
        add("Tools · Git", git_ok, "git available")
    except Exception as e:  # noqa: BLE001
        add("Tools", False, str(e))
    compose = Path(ROOT_DIR).parent / "deploy" / "open-webui" / "docker-compose.yml"
    add("Tools · Deployment", compose.exists(),
        "Open WebUI podman manifest ready" if compose.exists() else "manifest missing")
    add("Agent System", True, f"Planner + {', '.join(SPECIALISTS[r]['name'] for r in ROLE_ORDER)}")
    add("Interface", True, "Dashboard + Open WebUI (podman) supported")
    healthy = sum(1 for c in checks if c["ok"])
    return {"healthy": healthy, "total": len(checks), "checks": checks, "ts": datetime.now(timezone.utc).isoformat()}


@api.get("/settings")
async def read_settings():
    s = await get_settings()
    return {"has_key": bool(s["key"]), "model": s["model"], "base_url": OPENROUTER_BASE_URL}


@api.post("/settings")
async def write_settings(req: SettingsRequest):
    update: Dict[str, Any] = {}
    if req.openrouter_api_key is not None:
        update["openrouter_api_key"] = req.openrouter_api_key.strip()
    if req.model is not None:
        requested_model = req.model.strip()
        if not _is_safe_free_model(requested_model):
            raise HTTPException(400, "Only non-Google OpenRouter model IDs ending in :free are permitted.")
        update["model"] = requested_model
    if update:
        await db.settings.update_one({"_id": "app"}, {"$set": update}, upsert=True)
    s = await get_settings()
    return {"has_key": bool(s["key"]), "model": s["model"]}


FALLBACK_FREE_MODELS = [
    "nvidia/nemotron-3.5-lightning:free",
    "nvidia/nemotron-nano-9b-v2:free",
    "inclusionai/ling-3.0-flash:free",
    "openai/gpt-oss-20b:free",
    "meta-llama/llama-3.2-3b-instruct:free",
]


async def _fetch_free_models() -> List[str]:
    s = await get_settings()
    models: List[str] = []
    if s["key"]:
        try:
            llm = AsyncOpenAI(api_key=s["key"], base_url=OPENROUTER_BASE_URL)
            resp = await llm.models.list()
            for m in resp.data:
                mid = getattr(m, "id", "")
                pricing = getattr(m, "pricing", None)
                is_free = mid.endswith(":free")
                if pricing is not None:
                    try:
                        is_free = is_free or (
                            float(getattr(pricing, "prompt", 1) or 0) == 0
                            and float(getattr(pricing, "completion", 1) or 0) == 0)
                    except (TypeError, ValueError):
                        pass
                if is_free and mid and not mid.lower().startswith("google/"):
                    models.append(mid)
        except Exception as e:  # noqa: BLE001
            logger.warning(f"Could not fetch live models: {e}")
    if not models:
        models = list(FALLBACK_FREE_MODELS)
    return sorted(set(models))


@api.get("/models")
async def list_models():
    s = await get_settings()
    active = s["model"]
    models = await _fetch_free_models()
    seen, ordered = set(), []
    for mid in [active, DEFAULT_MODEL] + models:
        if mid and mid not in seen:
            seen.add(mid)
            ordered.append(mid)
    return {"models": ordered, "active": active}


@api.post("/chat")
async def chat(req: ChatRequest):
    s = await get_settings()
    llm = await get_llm()
    model = req.model or s["model"]
    session_id = req.session_id or str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.messages.insert_one({"id": str(uuid.uuid4()), "session_id": session_id,
                                  "role": "user", "content": req.message, "at": now})
    prior = await (db.messages.find({"session_id": session_id}, {"_id": 0}).sort("at", 1).limit(60).to_list(60))
    history = [{"role": m["role"], "content": m["content"]} for m in prior
               if m.get("role") in ("user", "assistant") and m.get("content")]
    reply = await complete(llm, model, NOVA_SYSTEM_PROMPT, history, temperature=0.6)
    await db.messages.insert_one({"id": str(uuid.uuid4()), "session_id": session_id, "role": "assistant",
                                  "content": reply, "model": model, "at": datetime.now(timezone.utc).isoformat()})
    return {"session_id": session_id, "reply": reply, "model": model}


@api.post("/chat/stream")
async def chat_stream(req: ChatRequest):
    s = await get_settings()
    llm = await get_llm()
    model = req.model or s["model"]
    session_id = req.session_id or str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.messages.insert_one({"id": str(uuid.uuid4()), "session_id": session_id,
                                  "role": "user", "content": req.message, "at": now})
    prior = await (db.messages.find({"session_id": session_id}, {"_id": 0}).sort("at", 1).limit(60).to_list(60))
    history = [{"role": m["role"], "content": m["content"]} for m in prior
               if m.get("role") in ("user", "assistant") and m.get("content")]

    async def gen():
        yield f"data: {json.dumps({'session_id': session_id})}\n\n"
        parts: List[str] = []
        try:
            stream = await llm.chat.completions.create(
                model=model, messages=[{"role": "system", "content": NOVA_SYSTEM_PROMPT}] + history,
                temperature=0.6, max_tokens=1400, stream=True, extra_headers=EXTRA_HEADERS)
            async for chunk in stream:
                delta = (chunk.choices[0].delta.content or "") if chunk.choices else ""
                if delta:
                    parts.append(delta)
                    yield f"data: {json.dumps({'delta': delta})}\n\n"
        except Exception as e:  # noqa: BLE001
            logger.exception("OpenRouter stream failed")
            yield f"data: {json.dumps({'error': f'OpenRouter request failed: {e}'})}\n\n"
            return
        reply = "".join(parts).strip()
        await db.messages.insert_one({"id": str(uuid.uuid4()), "session_id": session_id, "role": "assistant",
                                      "content": reply, "model": model, "at": datetime.now(timezone.utc).isoformat()})
        yield f"data: {json.dumps({'done': True, 'model': model})}\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"})


@api.get("/history/{session_id}")
async def history(session_id: str):
    msgs = await (db.messages.find({"session_id": session_id}, {"_id": 0}).sort("at", 1).to_list(500))
    return {"session_id": session_id, "messages": msgs}


@api.get("/sessions")
async def sessions():
    pipeline = [
        {"$sort": {"at": -1}},
        {"$group": {"_id": "$session_id", "last_message_at": {"$first": "$at"},
                    "last_content": {"$first": "$content"}, "count": {"$sum": 1}}},
        {"$sort": {"last_message_at": -1}}, {"$limit": 40}]
    rows = await db.messages.aggregate(pipeline).to_list(40)
    return [{"session_id": r["_id"], "last_message_at": r["last_message_at"],
             "preview": (r.get("last_content") or "")[:70], "message_count": r["count"]} for r in rows]


@api.post("/agents/plan")
async def agents_plan(req: PlanRequest):
    s = await get_settings()
    llm = await get_llm()
    model = req.model or s["model"]
    plan = await complete(llm, model, GENIE_SYSTEM,
                          [{"role": "user", "content": f"Goal from the operator:\n{req.goal}"}],
                          temperature=0.4, max_tokens=700)
    orders: List[Dict[str, str]] = []
    seen: set = set()
    for line in plan.splitlines():
        m = ORDER_RE.match(line)
        if m:
            role = m.group(1).lower()
            if role in seen:
                continue
            text = m.group(2).strip() or f"Contribute to this goal: {req.goal}"
            orders.append({"role": role, "name": SPECIALISTS[role]["name"], "order": text[:400]})
            seen.add(role)
    if not orders:
        orders = [{"role": r, "name": SPECIALISTS[r]["name"], "order": f"Contribute to this goal: {req.goal}"}
                  for r in ("research", "design", "code")]
    return {"acknowledgement": plan, "orders": orders, "model": model}


@api.post("/agents/dispatch")
async def agents_dispatch(req: DispatchRequest):
    role = req.role.lower()
    if role not in SPECIALISTS:
        raise HTTPException(400, f"Unknown role: {role}")
    s = await get_settings()
    llm = await get_llm()
    model = req.model or s["model"]
    user_msg = (f"Overall goal:\n{req.goal}\n\nYour specific order:\n{req.order}\n\n"
                "Deliver your part now, following your output format.")
    output = await complete(llm, model, SPECIALISTS[role]["system"],
                            [{"role": "user", "content": user_msg}], temperature=0.5, max_tokens=1600)
    return {"role": role, "name": SPECIALISTS[role]["name"], "order": req.order, "output": output}


@api.post("/agents/critic")
async def agents_critic(req: CriticRequest):
    s = await get_settings()
    llm = await get_llm()
    model = req.model or s["model"]
    body = "\n\n".join(f"## [{r.get('name', r.get('role'))}] {r.get('order','')}\n{r.get('output','')}" for r in req.results)
    prompt = (f"Original goal:\n{req.goal}\n\nAssembled team output:\n{body}\n\n"
              "Judge whether the assembled output satisfies the goal. Emit exactly:\n"
              "  VERDICT: PASS|FAIL\n  RATIONALE: one short paragraph\n  P0_ISSUES: bullets (or 'none')")
    verdict = await complete(llm, model, SPECIALISTS["qa"]["system"],
                             [{"role": "user", "content": prompt}], temperature=0.3, max_tokens=700)
    run_id = str(uuid.uuid4())
    await db.agent_runs.insert_one({"id": run_id, "goal": req.goal, "results": req.results,
                                    "verdict": verdict, "model": model, "at": datetime.now(timezone.utc).isoformat()})
    return {"run_id": run_id, "verdict": verdict, "model": model}


@api.get("/agents/runs")
async def agent_runs():
    rows = await db.agent_runs.find({}, {"_id": 0}).sort("at", -1).limit(20).to_list(20)
    return [{"id": r["id"], "goal": r["goal"], "at": r["at"],
             "verdict_head": (r.get("verdict") or "").splitlines()[0] if r.get("verdict") else ""} for r in rows]


# ---------- OpenAI-compatible proxy (Open WebUI plugs in here) ----------
def _enforce_free(model: Optional[str], fallback: str) -> str:
    # Every OpenRouter call crosses this gate, including user-selected models.
    return _safe_free_model(model, _safe_free_model(fallback, DEFAULT_MODEL))


@api.get("/v1/models")
async def openai_models():
    ids = await _fetch_free_models()
    now = int(datetime.now(timezone.utc).timestamp())
    return {"object": "list",
            "data": [{"id": mid, "object": "model", "created": now, "owned_by": "openrouter"} for mid in ids]}


@api.post("/v1/chat/completions")
async def openai_chat_completions(request: Request):
    body = await request.json()
    s = await get_settings()
    llm = await get_llm()
    model = _enforce_free(body.get("model"), s["model"])
    messages = body.get("messages") or []
    stream = bool(body.get("stream"))
    temperature = body.get("temperature", 0.6)
    max_tokens = body.get("max_tokens", 1400)
    if stream:
        async def gen():
            try:
                s_iter = await llm.chat.completions.create(
                    model=model, messages=messages, temperature=temperature,
                    max_tokens=max_tokens, stream=True, extra_headers=EXTRA_HEADERS)
                async for chunk in s_iter:
                    yield f"data: {json.dumps(chunk.model_dump())}\n\n"
            except Exception as e:  # noqa: BLE001
                yield f"data: {json.dumps({'error': str(e)})}\n\n"
            yield "data: [DONE]\n\n"
        return StreamingResponse(gen(), media_type="text/event-stream",
                                 headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"})
    try:
        completion = await llm.chat.completions.create(
            model=model, messages=messages, temperature=temperature,
            max_tokens=max_tokens, extra_headers=EXTRA_HEADERS)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(502, f"OpenRouter request failed: {e}")
    return completion.model_dump()


# ---------- Agent Runtime — ReAct loop with real Files/Shell/Git tools ----------
REACT_SYSTEM = (
    "You are the NOVA Coding Agent running inside an autonomous loop with REAL tools "
    "scoped to a sandbox workspace. Read before you write. Verify by running code.\n\n"
    + tools.describe_tools()
    + "\n\nReply with EXACTLY ONE JSON object and nothing else. Either:\n"
    '  {"thought": "...", "tool": "<name>", "args": {...}}   to act, or\n'
    '  {"thought": "...", "final": "<answer>"}               to finish.'
)
JSON_RE = re.compile(r"\{[\s\S]*\}")


def _extract_json(text: str) -> Optional[dict]:
    m = re.search(r"```(?:json)?\s*(\{[\s\S]*?\})\s*```", text)
    if m:
        try:
            return json.loads(m.group(1))
        except Exception:  # noqa: BLE001
            pass
    m = JSON_RE.search(text)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except Exception:  # noqa: BLE001
        return None


class ReactRequest(BaseModel):
    goal: str
    model: Optional[str] = None
    max_steps: int = 8


@api.post("/agents/react")
async def agents_react(req: ReactRequest):
    s = await get_settings()
    llm = await get_llm()
    model = req.model or s["model"]
    transcript: List[str] = [f"[user] {req.goal}"]
    steps: List[Dict[str, Any]] = []
    for i in range(max(1, min(req.max_steps, 12))):
        prompt = ("Conversation so far:\n" + "\n".join(transcript[-12:]) +
                  f"\n\nStep {i + 1}. Respond with one JSON action.")
        resp = await complete(llm, model, REACT_SYSTEM,
                              [{"role": "user", "content": prompt}], temperature=0.2, max_tokens=900)
        action = _extract_json(resp)
        if not action:
            transcript.append(f"[assistant] {resp}")
            transcript.append("[system] ERROR: emit ONE JSON action.")
            steps.append({"step": i + 1, "raw": resp[:400], "error": "no json action"})
            continue
        if "final" in action:
            steps.append({"step": i + 1, "final": action["final"]})
            return {"goal": req.goal, "model": model, "steps": steps, "final": action["final"]}
        tool_name = action.get("tool", "")
        args = action.get("args") or {}
        result = await asyncio.to_thread(tools.invoke, tool_name, args)
        transcript.append(f"[assistant] {json.dumps(action)}")
        transcript.append(f"[tool] {tool_name} -> {json.dumps(result)[:1200]}")
        steps.append({"step": i + 1, "thought": action.get("thought", ""),
                      "tool": tool_name, "args": args, "result": result})
    return {"goal": req.goal, "model": model, "steps": steps,
            "final": "Reached step budget without a final answer."}


# ---------- Phase 5 — Prove It (deterministic self-demonstration) ----------
ARCH_TEXT = (
    "podman Open WebUI -> OpenAI-compatible API -> OpenRouter proxy (free models) "
    "-> Agent Runtime -> Files / Shell / Git. NOVA (FastAPI + React + MongoDB) is the "
    "OpenAI-compatible OpenRouter proxy and hosts the sandboxed Agent Runtime."
)


@api.post("/system/prove")
async def system_prove():
    s = await get_settings()
    steps: List[Dict[str, Any]] = []

    def add(name, ok, detail):
        steps.append({"name": name, "ok": bool(ok), "detail": detail})

    try:
        listing = await asyncio.to_thread(lambda: sorted(p.name for p in Path(ROOT_DIR).iterdir()))
        head = Path(ROOT_DIR, "server.py").read_text()[:180]
        add("Reads its own repo", True,
            f"backend/ has {len(listing)} entries: {', '.join(listing[:8])}…\nserver.py starts:\n{head.strip()}")
    except Exception as e:  # noqa: BLE001
        add("Reads its own repo", False, str(e))
    try:
        llm = await get_llm()
        explanation = await complete(llm, s["model"],
            "You are NOVA explaining your own system. Be concise: 4-6 bullet points.",
            [{"role": "user", "content": f"Explain this architecture in plain terms:\n{ARCH_TEXT}"}],
            temperature=0.3, max_tokens=1200)
        add("Explains its architecture", bool(explanation.strip()), explanation)
    except Exception as e:  # noqa: BLE001
        add("Explains its architecture", False, str(e))
    try:
        await asyncio.to_thread(tools.fs_write, "sample.py", "def add(a, b):\n    return a + b\n")
        original_test = "from sample import add\n\ndef test_add():\n    assert add(2, 3) == 5\n"
        await asyncio.to_thread(tools.fs_write, "test_sample.py", original_test)
        modified_test = original_test + "\ndef test_add_negative():\n    assert add(-1, -1) == -2\n"
        w = await asyncio.to_thread(tools.fs_write, "test_sample.py", modified_test)
        add("Modifies a test file", w.get("backup_created", False),
            f"Wrote test_sample.py ({w.get('bytes')} bytes), backup_created={w.get('backup_created')}")
    except Exception as e:  # noqa: BLE001
        add("Modifies a test file", False, str(e))
    try:
        run = await asyncio.to_thread(tools.sh_run, f"{sys.executable} -m pytest -q test_sample.py", 60)
        add("Runs tests", run.get("exit_code") == 0,
            f"exit={run.get('exit_code')}\n{(run.get('stdout') or '')[-500:]}{(run.get('stderr') or '')[-300:]}")
    except Exception as e:  # noqa: BLE001
        add("Runs tests", False, str(e))
    try:
        await asyncio.to_thread(tools.git_run, "add -A")
        status = await asyncio.to_thread(tools.git_run, "status --short")
        diff = await asyncio.to_thread(tools.git_run, "diff --cached --stat")
        add("Reports changes", True,
            f"git status:\n{status.get('stdout','').strip() or '(clean)'}\n\nstaged diff:\n{diff.get('stdout','').strip()}")
    except Exception as e:  # noqa: BLE001
        add("Reports changes", False, str(e))
    try:
        r = await asyncio.to_thread(tools.fs_restore, "test_sample.py")
        current = await asyncio.to_thread(tools.fs_read, "test_sample.py")
        restored_ok = "test_add_negative" not in (current.get("content") or "")
        add("Restores from backup", restored_ok and "error" not in r,
            f"restored_from={r.get('restored_from')}; negative-test removed={restored_ok}")
    except Exception as e:  # noqa: BLE001
        add("Restores from backup", False, str(e))
    try:
        compose = Path(ROOT_DIR).parent / "deploy" / "open-webui" / "docker-compose.yml"
        wrote = await asyncio.to_thread(tools.fs_write, "deploy/docker-compose.yml",
                                        compose.read_text() if compose.exists() else "# generated\n")
        add("Prepares deployment", compose.exists(),
            f"Open WebUI manifest present at deploy/open-webui/docker-compose.yml\n"
            f"Agent authored workspace/deploy/docker-compose.yml ({wrote.get('bytes')} bytes)\n"
            f"Run: podman-compose -f deploy/open-webui/docker-compose.yml up -d")
    except Exception as e:  # noqa: BLE001
        add("Prepares deployment", False, str(e))
    passed = sum(1 for st in steps if st["ok"])
    return {"passed": passed, "total": len(steps), "steps": steps,
            "workspace": str(tools.WORKSPACE), "architecture": ARCH_TEXT}


app.include_router(api)
app.add_middleware(CORSMiddleware, allow_credentials=True,
                   allow_origins=[origin.strip() for origin in os.environ.get("CORS_ORIGINS", "http://127.0.0.1:3000,http://localhost:3000").split(",") if origin.strip()],
                   allow_methods=["*"], allow_headers=["*"])


@app.on_event("shutdown")
async def shutdown_db_client():
    client.close()
PY_SERVER

cat <<'TXT_REQ' > backend/requirements.txt
fastapi
uvicorn[standard]
motor
pymongo
openai>=1.40.0
python-dotenv
pydantic>=2.5
pytest
TXT_REQ

cat <<'ENV_BACK' > backend/.env
MONGO_URL="mongodb://localhost:27017"
DB_NAME="nova_sovereign"
CORS_ORIGINS="http://127.0.0.1:3000,http://localhost:3000"
OPENROUTER_API_KEY=""
OPENROUTER_BASE_URL="https://openrouter.ai/api/v1"
OPENROUTER_MODEL="nvidia/nemotron-3.5-lightning:free"
ENV_BACK

# ----------------------------------------------------------------------------
# FRONTEND · configs
# ----------------------------------------------------------------------------
cat <<'PKG_JSON' > frontend/package.json
{
  "name": "nova-frontend",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "@tanstack/react-query": "^5.56.2",
    "axios": "^1.7.9",
    "framer-motion": "^11.18.0",
    "lucide-react": "^0.516.0",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-markdown": "^9.0.1",
    "remark-gfm": "^4.0.0"
  },
  "devDependencies": {
    "@tailwindcss/postcss": "^4.3.3",
    "@vitejs/plugin-react": "^6.1.2",
    "autoprefixer": "^10.4.20",
    "postcss": "^8.4.49",
    "tailwindcss": "^4.3.3",
    "vite": "^8.3.4"
  },
  "scripts": {
    "start": "vite",
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  }
}
PKG_JSON

cat <<'VITE_CONFIG' > frontend/vite.config.mjs
import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
const here = path.dirname(fileURLToPath(import.meta.url));
export default defineConfig({
  plugins: [react()],
  resolve: { alias: { "@": path.resolve(here, "src") } },
  server: { host: "127.0.0.1", port: 3000, strictPort: true },
  preview: { host: "127.0.0.1", port: 4173, strictPort: true }
});
VITE_CONFIG

cat <<'POSTCSS' > frontend/postcss.config.js
module.exports = {
  plugins: {
    "@tailwindcss/postcss": {},
    autoprefixer: {},
  },
};
POSTCSS

cat <<'TAILWIND' > frontend/tailwind.config.js
/** @type {import('tailwindcss').Config} */
module.exports = {
  darkMode: ["class"],
  content: ["./index.html", "./src/**/*.{js,jsx,ts,tsx}"],
  theme: {
    extend: {
      colors: {
        background: "hsl(var(--background))",
        foreground: "hsl(var(--foreground))",
        border: "hsl(var(--border))",
        primary: { DEFAULT: "hsl(var(--primary))", foreground: "hsl(var(--primary-foreground))" },
        accent: { DEFAULT: "hsl(var(--accent))", foreground: "hsl(var(--accent-foreground))" },
      },
    },
  },
  plugins: [],
};
TAILWIND

cat <<'JSCONFIG' > frontend/jsconfig.json
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": { "@/*": ["src/*"] }
  },
  "include": ["src"]
}
JSCONFIG

rm -f frontend/public/index.html frontend/craco.config.js
cat <<'ENV_FRONT' > frontend/.env
VITE_BACKEND_URL=http://127.0.0.1:8001
ENV_FRONT

cat <<'HTML_INDEX' > frontend/index.html
<!DOCTYPE html>
<html lang="en" class="dark">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="theme-color" content="#050506" />
    <meta name="description" content="NOVA — a sovereign, open AI workspace. Free chat + a self-organizing agent team, powered entirely by free OpenRouter models." />
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link href="https://fonts.googleapis.com/css2?family=Unbounded:wght@400;600;700;800&family=IBM+Plex+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet" />
    <title>NOVA · Sovereign AI</title>
  </head>
  <body>
    <noscript>You need to enable JavaScript to run NOVA.</noscript>
    <div id="root"></div>
    <script type="module" src="/src/index.jsx"></script>
  </body>
</html>
HTML_INDEX

# ----------------------------------------------------------------------------
# FRONTEND · src
# ----------------------------------------------------------------------------
cat <<'JS_INDEX' > frontend/src/index.jsx
import React from "react";
import ReactDOM from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import "@/index.css";
import App from "@/App";

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 60000, refetchOnWindowFocus: false } },
});

const root = ReactDOM.createRoot(document.getElementById("root"));
root.render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  </React.StrictMode>,
);
JS_INDEX

cat <<'JS_APP' > frontend/src/App.js
import "@/App.css";
import Nova from "@/components/Nova";

function App() {
  return (
    <div className="App">
      <Nova />
    </div>
  );
}

export default App;
JS_APP

cat <<'CSS_APP' > frontend/src/App.css
.App {
  height: 100vh;
  width: 100vw;
}
CSS_APP

cat <<'CSS_INDEX' > frontend/src/index.css
@import "tailwindcss";
@config "../tailwind.config.js";

:root {
  --background: 240 6% 3%;
  --foreground: 210 17% 96%;
  --primary: 158 100% 50%;
  --primary-foreground: 240 6% 3%;
  --accent: 187 100% 50%;
  --accent-foreground: 240 6% 3%;
  --border: 240 6% 15%;
  --radius: 0.75rem;
}

* { border-color: hsl(var(--border)); }
html, body, #root { height: 100%; }

body {
  margin: 0;
  background-color: #050506;
  color: hsl(var(--foreground));
  font-family: "IBM Plex Sans", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
  overflow: hidden;
}

.font-heading { font-family: "Unbounded", sans-serif; }
.font-mono { font-family: "JetBrains Mono", monospace; }

.nova-bg {
  position: relative;
  background:
    radial-gradient(900px 500px at 15% -10%, rgba(0, 255, 157, 0.08), transparent 60%),
    radial-gradient(800px 500px at 100% 0%, rgba(0, 229, 255, 0.06), transparent 55%),
    #050506;
}
.nova-bg::before {
  content: "";
  position: absolute;
  inset: 0;
  pointer-events: none;
  opacity: 0.04;
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
}

.glass {
  background: rgba(10, 10, 12, 0.6);
  backdrop-filter: blur(18px);
  -webkit-backdrop-filter: blur(18px);
  border: 1px solid rgba(255, 255, 255, 0.08);
}
.glow-primary { box-shadow: 0 0 18px rgba(0, 255, 157, 0.35); }

.tracing { position: relative; overflow: hidden; }
.tracing::after {
  content: "";
  position: absolute;
  inset: -2px;
  border-radius: inherit;
  padding: 1px;
  background: conic-gradient(from var(--angle, 0deg), transparent 0%, #00ff9d 15%, #00e5ff 30%, transparent 45%);
  -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
  -webkit-mask-composite: xor;
  mask-composite: exclude;
  animation: spin-border 2.4s linear infinite;
}
@property --angle { syntax: "<angle>"; initial-value: 0deg; inherits: false; }
@keyframes spin-border { to { --angle: 360deg; } }

@keyframes pulse-dot {
  0%, 100% { opacity: 1; box-shadow: 0 0 0 0 rgba(0, 255, 157, 0.5); }
  50% { opacity: 0.6; box-shadow: 0 0 0 6px rgba(0, 255, 157, 0); }
}
.pulse-dot { animation: pulse-dot 1.6s ease-in-out infinite; }

.blink-cursor::after {
  content: "\2588";
  margin-left: 2px;
  animation: blink 1s steps(2, start) infinite;
  color: #00ff9d;
}
@keyframes blink { to { visibility: hidden; } }

*::-webkit-scrollbar { width: 8px; height: 8px; }
*::-webkit-scrollbar-track { background: transparent; }
*::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.1); border-radius: 8px; }
*::-webkit-scrollbar-thumb:hover { background: rgba(0, 255, 157, 0.4); }

.md :is(h1, h2, h3) { font-family: "Unbounded", sans-serif; font-weight: 700; margin: 0.8em 0 0.4em; line-height: 1.2; }
.md h1 { font-size: 1.3rem; } .md h2 { font-size: 1.15rem; } .md h3 { font-size: 1rem; }
.md p { margin: 0.5em 0; line-height: 1.65; }
.md ul, .md ol { margin: 0.5em 0; padding-left: 1.3em; }
.md li { margin: 0.25em 0; }
.md a { color: #00e5ff; text-decoration: underline; }
.md code { font-family: "JetBrains Mono", monospace; font-size: 0.85em; background: rgba(0, 255, 157, 0.1); color: #7dffce; padding: 0.1em 0.35em; border-radius: 4px; }
.md pre { background: #0a0a0c; border: 1px solid rgba(255, 255, 255, 0.08); border-radius: 10px; padding: 14px 16px; overflow-x: auto; margin: 0.7em 0; }
.md pre code { background: transparent; color: #d7e0e8; padding: 0; }
.md strong { color: #fff; font-weight: 600; }

@media (prefers-reduced-motion: reduce) {
  .tracing::after, .pulse-dot, .blink-cursor::after { animation: none; }
}
CSS_INDEX

cat <<'JS_API' > frontend/src/api.js
import axios from "axios";

const BACKEND_URL = import.meta.env.VITE_BACKEND_URL || "http://127.0.0.1:8001";
export const API = `${BACKEND_URL}/api`;

const http = axios.create({ baseURL: API, timeout: 120000 });

export const api = {
  getSettings: () => http.get("/settings").then((r) => r.data),
  saveSettings: (body) => http.post("/settings", body).then((r) => r.data),
  getModels: () => http.get("/models").then((r) => r.data),
  chat: (body) => http.post("/chat", body).then((r) => r.data),
  getSessions: () => http.get("/sessions").then((r) => r.data),
  getHistory: (id) => http.get(`/history/${id}`).then((r) => r.data),
  plan: (body) => http.post("/agents/plan", body).then((r) => r.data),
  dispatch: (body) => http.post("/agents/dispatch", body).then((r) => r.data),
  critic: (body) => http.post("/agents/critic", body).then((r) => r.data),
  runs: () => http.get("/agents/runs").then((r) => r.data),
  systemHealth: () => http.get("/system/health").then((r) => r.data),
  prove: () => http.post("/system/prove").then((r) => r.data),
};

export function errText(e) {
  return e?.response?.data?.detail || e?.message || "Something went wrong";
}
JS_API

cat <<'JSX_MD' > frontend/src/components/Markdown.jsx
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

export default function Markdown({ children, className = "" }) {
  return (
    <div className={`md ${className}`}>
      <ReactMarkdown remarkPlugins={[remarkGfm]}>{children || ""}</ReactMarkdown>
    </div>
  );
}
JSX_MD

cat <<'JSX_SETTINGS' > frontend/src/components/SettingsDialog.jsx
import { useState, useEffect } from "react";
import { X, KeyRound, Cpu, Check, Loader2, ExternalLink } from "lucide-react";
import { motion, AnimatePresence } from "framer-motion";
import { api, errText } from "@/api";

export default function SettingsDialog({ open, onClose, settings, models, activeModel, onSaved }) {
  const [key, setKey] = useState("");
  const [model, setModel] = useState(activeModel);
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState("");

  useEffect(() => {
    setModel(activeModel);
  }, [activeModel, open]);

  const save = async () => {
    setSaving(true);
    setMsg("");
    try {
      const body = { model };
      if (key.trim()) body.openrouter_api_key = key.trim();
      const res = await api.saveSettings(body);
      setMsg("Saved");
      setKey("");
      onSaved?.(res);
      setTimeout(() => onClose(), 500);
    } catch (e) {
      setMsg(errText(e));
    } finally {
      setSaving(false);
    }
  };

  return (
    <AnimatePresence>
      {open && (
        <motion.div
          className="fixed inset-0 z-[100] flex items-center justify-center p-4"
          initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
          data-testid="settings-modal"
        >
          <div className="absolute inset-0 bg-black/70 backdrop-blur-sm" onClick={onClose} />
          <motion.div
            className="glass relative z-10 w-full max-w-lg rounded-2xl p-6"
            initial={{ scale: 0.94, y: 12 }} animate={{ scale: 1, y: 0 }} exit={{ scale: 0.94, y: 12 }}
            transition={{ type: "spring", stiffness: 300, damping: 26 }}
          >
            <div className="mb-5 flex items-center justify-between">
              <h2 className="font-heading text-xl font-bold text-white">Settings</h2>
              <button onClick={onClose} className="rounded-lg p-1.5 text-zinc-400 hover:bg-white/5 hover:text-white" data-testid="settings-close-btn">
                <X size={18} />
              </button>
            </div>

            <label className="mb-1.5 flex items-center gap-2 text-xs font-mono uppercase tracking-wider text-zinc-400">
              <KeyRound size={13} /> OpenRouter API Key
            </label>
            <input
              type="password" value={key} onChange={(e) => setKey(e.target.value)}
              placeholder={settings?.has_key ? "•••••••• (configured — leave blank to keep)" : "sk-or-v1-..."}
              className="w-full rounded-lg border border-white/10 bg-black/40 px-3 py-2.5 font-mono text-sm text-white outline-none focus:border-[#00FF9D]"
              data-testid="settings-key-input"
            />
            <a href="https://openrouter.ai/keys" target="_blank" rel="noreferrer" className="mt-1.5 inline-flex items-center gap-1 text-xs text-[#00E5FF] hover:underline">
              Get a free key <ExternalLink size={11} />
            </a>

            <label className="mb-1.5 mt-5 flex items-center gap-2 text-xs font-mono uppercase tracking-wider text-zinc-400">
              <Cpu size={13} /> Free Model
            </label>
            <select value={model} onChange={(e) => setModel(e.target.value)}
              className="w-full rounded-lg border border-white/10 bg-black/40 px-3 py-2.5 font-mono text-sm text-white outline-none focus:border-[#00FF9D]"
              data-testid="settings-model-select"
            >
              {models.map((m) => (<option key={m} value={m} className="bg-[#0C0C0E]">{m}</option>))}
            </select>

            <div className="mt-6 flex items-center justify-between">
              <span className={`text-sm ${msg === "Saved" ? "text-[#00FF9D]" : "text-[#FF3366]"}`} data-testid="settings-msg">
                {msg === "Saved" ? (<span className="flex items-center gap-1"><Check size={14} /> Saved</span>) : (msg)}
              </span>
              <button onClick={save} disabled={saving}
                className="glow-primary inline-flex items-center gap-2 rounded-lg bg-[#00FF9D] px-5 py-2.5 text-sm font-semibold text-black transition-transform hover:-translate-y-0.5 disabled:opacity-60"
                data-testid="settings-save-btn"
              >
                {saving && <Loader2 size={15} className="animate-spin" />}
                Save
              </button>
            </div>
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
JSX_SETTINGS

cat <<'JSX_NOVA' > frontend/src/components/Nova.jsx
import { useState, useEffect, useCallback } from "react";
import { motion } from "framer-motion";
import { MessagesSquare, Boxes, Settings2, Sparkles, ChevronDown, LayoutDashboard } from "lucide-react";
import { api } from "@/api";
import ChatMode from "@/components/ChatMode";
import AgentTeamMode from "@/components/AgentTeamMode";
import DashboardMode from "@/components/DashboardMode";
import SettingsDialog from "@/components/SettingsDialog";

export default function Nova() {
  const [mode, setMode] = useState("chat");
  const [settings, setSettings] = useState({ has_key: false, model: "" });
  const [models, setModels] = useState([]);
  const [activeModel, setActiveModel] = useState("");
  const [showSettings, setShowSettings] = useState(false);
  const [modelOpen, setModelOpen] = useState(false);

  const loadModels = useCallback(async () => {
    try {
      const m = await api.getModels();
      setModels(m.models || []);
      setActiveModel(m.active || "");
    } catch (e) { /* backend may lack a key yet */ }
  }, []);

  useEffect(() => {
    api.getSettings().then((s) => {
      setSettings(s);
      setActiveModel(s.model);
      if (!s.has_key) setShowSettings(true);
    });
    loadModels();
  }, [loadModels]);

  const pickModel = async (m) => {
    setActiveModel(m);
    setModelOpen(false);
    await api.saveSettings({ model: m });
  };

  const navItems = [
    { id: "chat", label: "Chat", icon: MessagesSquare },
    { id: "agents", label: "Agent Team", icon: Boxes },
    { id: "dashboard", label: "Dashboard", icon: LayoutDashboard },
  ];

  return (
    <div className="nova-bg flex h-screen w-screen overflow-hidden text-white">
      <aside className="glass z-40 flex w-[76px] flex-col items-center gap-2 border-r border-white/10 py-5 md:w-[240px] md:items-stretch md:px-4" data-testid="nav-rail">
        <div className="mb-6 flex items-center gap-2.5 px-1 md:px-2">
          <div className="glow-primary flex h-9 w-9 items-center justify-center rounded-xl bg-[#00FF9D] text-black">
            <Sparkles size={18} />
          </div>
          <div className="hidden md:block">
            <div className="font-heading text-lg font-extrabold leading-none tracking-tight">NOVA</div>
            <div className="font-mono text-[10px] uppercase tracking-[0.2em] text-[#00FF9D]">Sovereign AI</div>
          </div>
        </div>

        {navItems.map((n) => {
          const Icon = n.icon;
          const active = mode === n.id;
          return (
            <button key={n.id} onClick={() => setMode(n.id)} data-testid={`nav-${n.id}`}
              className={`group flex items-center gap-3 rounded-xl px-3 py-3 transition-colors md:justify-start ${active ? "bg-white/[0.07] text-white" : "text-zinc-400 hover:bg-white/5 hover:text-white"}`}
            >
              <Icon size={20} className={active ? "text-[#00FF9D]" : ""} />
              <span className="hidden text-sm font-medium md:inline">{n.label}</span>
              {active && (<motion.span layoutId="nav-active" className="ml-auto hidden h-2 w-2 rounded-full bg-[#00FF9D] md:block" />)}
            </button>
          );
        })}

        <div className="mt-auto">
          <button onClick={() => setShowSettings(true)} data-testid="nav-settings"
            className="flex w-full items-center gap-3 rounded-xl px-3 py-3 text-zinc-400 transition-colors hover:bg-white/5 hover:text-white">
            <Settings2 size={20} />
            <span className="hidden text-sm font-medium md:inline">Settings</span>
          </button>
        </div>
      </aside>

      <main className="flex min-w-0 flex-1 flex-col">
        <header className="glass z-30 flex items-center justify-between border-b border-white/10 px-5 py-3" data-testid="model-status-bar">
          <div className="flex items-center gap-2.5">
            <span className={`pulse-dot h-2.5 w-2.5 rounded-full ${settings.has_key ? "bg-[#00FF9D]" : "bg-[#FF3366]"}`} />
            <span className="font-mono text-xs text-zinc-400">
              {settings.has_key ? "OpenRouter · free tier" : "No key — configure in Settings"}
            </span>
          </div>

          <div className="relative">
            <button onClick={() => setModelOpen((o) => !o)} data-testid="model-switcher"
              className="flex items-center gap-2 rounded-lg border border-white/10 bg-black/40 px-3 py-1.5 font-mono text-xs text-white hover:border-[#00FF9D]/50">
              <span className="max-w-[240px] truncate">{activeModel || "select model"}</span>
              <ChevronDown size={14} className={`transition-transform ${modelOpen ? "rotate-180" : ""}`} />
            </button>
            {modelOpen && (
              <>
                <div className="fixed inset-0 z-40" onClick={() => setModelOpen(false)} />
                <div className="glass absolute right-0 z-50 mt-2 max-h-80 w-[320px] overflow-y-auto rounded-xl p-1.5" data-testid="model-list">
                  {models.length === 0 && (<div className="px-3 py-2 font-mono text-xs text-zinc-500">No models loaded</div>)}
                  {models.map((m) => (
                    <button key={m} onClick={() => pickModel(m)} data-testid={`model-option-${m}`}
                      className={`block w-full truncate rounded-lg px-3 py-2 text-left font-mono text-xs transition-colors hover:bg-white/5 ${m === activeModel ? "text-[#00FF9D]" : "text-zinc-300"}`}>
                      {m}
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
        </header>

        <section className="min-h-0 flex-1">
          {mode === "chat" && <ChatMode activeModel={activeModel} hasKey={settings.has_key} />}
          {mode === "agents" && <AgentTeamMode activeModel={activeModel} hasKey={settings.has_key} />}
          {mode === "dashboard" && <DashboardMode hasKey={settings.has_key} />}
        </section>
      </main>

      <SettingsDialog
        open={showSettings} onClose={() => setShowSettings(false)}
        settings={settings} models={models} activeModel={activeModel}
        onSaved={(res) => {
          setSettings((s) => ({ ...s, has_key: res.has_key, model: res.model }));
          setActiveModel(res.model);
          loadModels();
        }}
      />
    </div>
  );
}
JSX_NOVA

cat <<'JSX_CHAT' > frontend/src/components/ChatMode.jsx
import { useState, useEffect, useRef, useCallback } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { Send, Plus, Loader2, Sparkles, History } from "lucide-react";
import { api, errText, API } from "@/api";
import Markdown from "@/components/Markdown";

export default function ChatMode({ activeModel, hasKey }) {
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState(null);
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState("");
  const feedRef = useRef(null);

  const loadSessions = useCallback(() => api.getSessions().then(setSessions).catch(() => {}), []);

  useEffect(() => { loadSessions(); }, [loadSessions]);
  useEffect(() => {
    feedRef.current?.scrollTo({ top: feedRef.current.scrollHeight, behavior: "smooth" });
  }, [messages, sending]);

  const openSession = async (id) => {
    setSessionId(id);
    setError("");
    const h = await api.getHistory(id);
    setMessages(h.messages || []);
  };

  const newChat = () => { setSessionId(null); setMessages([]); setInput(""); setError(""); };

  const send = async () => {
    const text = input.trim();
    if (!text || sending || !hasKey) return;
    setError("");
    setInput("");
    setMessages((m) => [...m, { role: "user", content: text }, { role: "assistant", content: "", model: activeModel, streaming: true }]);
    setSending(true);
    try {
      const resp = await fetch(`${API}/chat/stream`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: text, session_id: sessionId, model: activeModel }),
      });
      if (!resp.ok || !resp.body) throw new Error(await resp.text());

      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let streamErr = "";

      const pump = async () => {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const chunks = buffer.split("\n\n");
          buffer = chunks.pop();
          for (const chunk of chunks) {
            const line = chunk.replace(/^data:\s?/, "").trim();
            if (!line) continue;
            let evt;
            try { evt = JSON.parse(line); } catch { continue; }
            if (evt.session_id) setSessionId(evt.session_id);
            if (evt.delta) {
              setMessages((m) => {
                const c = [...m];
                const last = c[c.length - 1];
                c[c.length - 1] = { ...last, content: last.content + evt.delta };
                return c;
              });
            }
            if (evt.error) streamErr = evt.error;
            if (evt.done) {
              setMessages((m) => {
                const c = [...m];
                c[c.length - 1] = { ...c[c.length - 1], streaming: false, model: evt.model };
                return c;
              });
            }
          }
        }
      };
      await pump();
      if (streamErr) throw new Error(streamErr);
      loadSessions();
    } catch (e) {
      setError(errText(e));
      setMessages((m) => {
        const c = [...m];
        if (c.length && c[c.length - 1].role === "assistant" && !c[c.length - 1].content) c.pop();
        return c;
      });
      setInput(text);
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="flex h-full min-h-0">
      <div className="hidden w-[260px] flex-col border-r border-white/10 lg:flex" data-testid="chat-sessions">
        <div className="p-3">
          <button onClick={newChat} data-testid="new-chat-btn"
            className="flex w-full items-center justify-center gap-2 rounded-xl border border-[#00FF9D]/30 bg-[#00FF9D]/10 py-2.5 text-sm font-medium text-[#00FF9D] transition-colors hover:bg-[#00FF9D]/20">
            <Plus size={16} /> New chat
          </button>
        </div>
        <div className="mb-1 flex items-center gap-2 px-4 font-mono text-[10px] uppercase tracking-widest text-zinc-500">
          <History size={11} /> Sessions
        </div>
        <div className="min-h-0 flex-1 space-y-1 overflow-y-auto px-2 pb-3">
          {sessions.length === 0 && (<p className="px-2 py-3 text-xs text-zinc-600">No conversations yet.</p>)}
          {sessions.map((s) => (
            <button key={s.session_id} onClick={() => openSession(s.session_id)} data-testid={`session-${s.session_id}`}
              className={`block w-full rounded-lg px-3 py-2.5 text-left transition-colors hover:bg-white/5 ${s.session_id === sessionId ? "bg-white/[0.06]" : ""}`}>
              <div className="truncate text-sm text-zinc-200">{s.preview || "Untitled"}</div>
              <div className="font-mono text-[10px] text-zinc-600">{s.message_count} msgs</div>
            </button>
          ))}
        </div>
      </div>

      <div className="flex min-w-0 flex-1 flex-col">
        <div ref={feedRef} className="min-h-0 flex-1 overflow-y-auto px-4 py-6" data-testid="chat-feed">
          <div className="mx-auto max-w-[820px] space-y-6">
            {messages.length === 0 && (
              <div className="flex flex-col items-center justify-center py-20 text-center">
                <div className="glow-primary mb-5 flex h-14 w-14 items-center justify-center rounded-2xl bg-[#00FF9D] text-black">
                  <Sparkles size={26} />
                </div>
                <h1 className="font-heading text-3xl font-extrabold">Talk to NOVA</h1>
                <p className="mt-2 max-w-md text-sm text-zinc-400">Your sovereign, open AI sidekick. Ask anything — running free on OpenRouter.</p>
              </div>
            )}

            <AnimatePresence initial={false}>
              {messages.map((m, i) => (
                <motion.div key={i} initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }}
                  className={m.role === "user" ? "flex justify-end" : "flex justify-start"}>
                  {m.role === "user" ? (
                    <div className="max-w-[80%] rounded-2xl rounded-br-md border border-white/5 bg-[#141417] px-4 py-3 text-[15px] leading-relaxed text-zinc-100" data-testid="msg-user">
                      {m.content}
                    </div>
                  ) : (
                    <div className="max-w-[88%] border-l-2 border-[#00FF9D] bg-transparent py-1 pl-4 pr-2 text-[15px] leading-relaxed text-zinc-100" data-testid="msg-assistant">
                      {m.content ? (<Markdown>{m.content}</Markdown>) : (<span className="blink-cursor text-zinc-400">NOVA is thinking</span>)}
                      {m.streaming && m.content && <span className="blink-cursor" />}
                      {m.model && !m.streaming && (<div className="mt-2 font-mono text-[10px] text-zinc-600">{m.model}</div>)}
                    </div>
                  )}
                </motion.div>
              ))}
            </AnimatePresence>
          </div>
        </div>

        <div className="border-t border-white/10 px-4 py-4">
          <div className="mx-auto max-w-[820px]">
            {error && (<div className="mb-2 text-xs text-[#FF3366]" data-testid="chat-error">{error}</div>)}
            <div className="glass flex items-end gap-2 rounded-2xl p-2">
              <textarea rows={1} value={input} onChange={(e) => setInput(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } }}
                placeholder={hasKey ? "Message NOVA…" : "Add an OpenRouter key in Settings to begin"}
                disabled={!hasKey} data-testid="chat-input"
                className="max-h-40 min-h-[44px] flex-1 resize-none bg-transparent px-3 py-2.5 text-[15px] text-white outline-none placeholder:text-zinc-600 disabled:opacity-60" />
              <button onClick={send} disabled={sending || !input.trim() || !hasKey} data-testid="chat-send-btn"
                className="glow-primary flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-[#00FF9D] text-black transition-transform hover:-translate-y-0.5 disabled:opacity-40 disabled:hover:translate-y-0">
                {sending ? <Loader2 size={18} className="animate-spin" /> : <Send size={18} />}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
JSX_CHAT

cat <<'JSX_AGENT' > frontend/src/components/AgentTeamMode.jsx
import { useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { Search, Palette, Code2, ShieldCheck, FileText, Plug, Zap, Loader2, Wrench, CheckCircle2, ChevronDown, Gavel, Copy, Download, ClipboardCheck } from "lucide-react";
import { api, errText } from "@/api";
import Markdown from "@/components/Markdown";

const ROLE_META = {
  research: { icon: Search, label: "Research" },
  design: { icon: Palette, label: "Design" },
  code: { icon: Code2, label: "Coding" },
  qa: { icon: ShieldCheck, label: "QA" },
  report: { icon: FileText, label: "Reporting" },
  integration: { icon: Plug, label: "Integration" },
  repair: { icon: Wrench, label: "Repair" },
};

const STATUS_LABEL = { queued: "Queued", running: "Running", done: "Done", error: "Error" };

function AgentCard({ agent, index, expanded, onToggle }) {
  const meta = ROLE_META[agent.role] || { icon: Zap, label: agent.role };
  const Icon = meta.icon;
  const running = agent.status === "running";
  const done = agent.status === "done";

  return (
    <motion.div initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: index * 0.05 }}
      className={`rounded-2xl ${running ? "tracing" : ""}`} data-testid={`agent-card-${agent.role}`}>
      <div className="glass h-full rounded-2xl p-4">
        <div className="flex items-start gap-3">
          <div className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border ${done ? "border-[#00FF9D]/40 bg-[#00FF9D]/10 text-[#00FF9D]" : running ? "border-[#00E5FF]/40 bg-[#00E5FF]/10 text-[#00E5FF]" : "border-white/10 bg-black/40 text-zinc-500"} ${running ? "pulse-dot" : ""}`}>
            <Icon size={18} />
          </div>
          <div className="min-w-0 flex-1">
            <div className="flex items-center justify-between">
              <h3 className="font-heading text-sm font-bold text-white">{meta.label}</h3>
              <span className={`font-mono text-[10px] uppercase tracking-wider ${done ? "text-[#00FF9D]" : running ? "text-[#00E5FF]" : agent.status === "error" ? "text-[#FF3366]" : "text-zinc-500"}`} data-testid={`agent-status-${agent.role}`}>
                {STATUS_LABEL[agent.status]}
              </span>
            </div>
            <p className="mt-1 line-clamp-2 text-xs leading-relaxed text-zinc-400">{agent.order}</p>
          </div>
        </div>

        {done && (
          <button onClick={onToggle} data-testid={`agent-toggle-${agent.role}`}
            className="mt-3 flex w-full items-center justify-between rounded-lg border border-white/5 bg-black/30 px-3 py-2 text-xs text-zinc-300 hover:bg-white/5">
            <span className="flex items-center gap-1.5"><CheckCircle2 size={13} className="text-[#00FF9D]" /> View output</span>
            <ChevronDown size={14} className={`transition-transform ${expanded ? "rotate-180" : ""}`} />
          </button>
        )}

        <AnimatePresence>
          {expanded && done && (
            <motion.div initial={{ height: 0, opacity: 0 }} animate={{ height: "auto", opacity: 1 }} exit={{ height: 0, opacity: 0 }} className="overflow-hidden">
              <div className="mt-3 max-h-96 overflow-y-auto rounded-lg border border-white/5 bg-black/40 p-3 text-[13px] text-zinc-200">
                <Markdown>{agent.output}</Markdown>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </motion.div>
  );
}

export default function AgentTeamMode({ activeModel, hasKey }) {
  const [goal, setGoal] = useState("");
  const [running, setRunning] = useState(false);
  const [ack, setAck] = useState("");
  const [agents, setAgents] = useState([]);
  const [verdict, setVerdict] = useState("");
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState({});
  const [copied, setCopied] = useState(false);

  const verdictPass = verdict && /VERDICT:\s*PASS/i.test(verdict);

  const buildReport = () => {
    const stamp = new Date().toISOString();
    let md = `# NOVA · Agent Team Report\n\n`;
    md += `**Goal:** ${goal}\n\n`;
    md += `**Model:** ${activeModel}\n\n`;
    md += `**Generated:** ${stamp}\n\n---\n\n`;
    if (ack) md += `## Genie · Plan\n\n${ack}\n\n`;
    agents.forEach((a) => {
      const label = ROLE_META[a.role]?.label || a.role;
      md += `## ${label}\n\n> Order: ${a.order}\n\n${a.output || "_(no output)_"}\n\n`;
    });
    if (verdict) md += `## QA Critic Verdict\n\n${verdict}\n`;
    return md;
  };

  const copyReport = async () => {
    try {
      await navigator.clipboard.writeText(buildReport());
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch { /* clipboard blocked */ }
  };

  const downloadReport = () => {
    const blob = new Blob([buildReport()], { type: "text/markdown;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `nova-agent-report-${Date.now()}.md`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  };

  const deploy = async () => {
    const g = goal.trim();
    if (!g || running || !hasKey) return;
    setRunning(true); setError(""); setAck(""); setVerdict(""); setAgents([]); setExpanded({});
    try {
      const plan = await api.plan({ goal: g, model: activeModel });
      setAck(plan.acknowledgement);
      let list = plan.orders.map((o) => ({ ...o, status: "queued", output: "" }));
      setAgents(list);
      for (let i = 0; i < list.length; i++) {
        list = list.map((a, idx) => (idx === i ? { ...a, status: "running" } : a));
        setAgents([...list]);
        try {
          const res = await api.dispatch({ goal: g, role: list[i].role, order: list[i].order, model: activeModel });
          list = list.map((a, idx) => (idx === i ? { ...a, status: "done", output: res.output } : a));
        } catch (e) {
          list = list.map((a, idx) => (idx === i ? { ...a, status: "error", output: errText(e) } : a));
        }
        setAgents([...list]);
      }
      const done = list.filter((a) => a.status === "done");
      if (done.length) {
        const cr = await api.critic({ goal: g, results: done, model: activeModel });
        setVerdict(cr.verdict);
      }
    } catch (e) {
      setError(errText(e));
    } finally {
      setRunning(false);
    }
  };

  return (
    <div className="h-full overflow-y-auto px-5 py-6" data-testid="agent-team-mode">
      <div className="mx-auto max-w-6xl">
        <div className="mb-8">
          <div className="mb-2 flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.2em] text-[#00FF9D]">
            <Zap size={12} /> Command Center
          </div>
          <textarea rows={2} value={goal} onChange={(e) => setGoal(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) deploy(); }}
            placeholder="Give the team a mission — e.g. 'Design and build a landing page for a coffee subscription startup'"
            disabled={!hasKey || running} data-testid="goal-input"
            className="w-full resize-none border-b-2 border-white/10 bg-transparent pb-3 font-heading text-2xl font-semibold text-white outline-none transition-colors placeholder:text-zinc-700 focus:border-[#00FF9D] disabled:opacity-60" />
          <div className="mt-4 flex items-center justify-between">
            <p className="font-mono text-[11px] text-zinc-600">
              {hasKey ? "Genie plans → specialists dispatch → QA critic gates" : "Add an OpenRouter key in Settings"}
            </p>
            <button onClick={deploy} disabled={running || !goal.trim() || !hasKey} data-testid="deploy-team-btn"
              className="glow-primary inline-flex items-center gap-2 rounded-xl bg-[#00FF9D] px-6 py-3 text-sm font-semibold text-black transition-transform hover:-translate-y-0.5 disabled:opacity-40 disabled:hover:translate-y-0">
              {running ? <Loader2 size={17} className="animate-spin" /> : <Zap size={17} />}
              {running ? "Team working…" : "Deploy Team"}
            </button>
          </div>
        </div>

        {error && (<div className="mb-6 rounded-xl border border-[#FF3366]/30 bg-[#FF3366]/10 px-4 py-3 text-sm text-[#FF3366]" data-testid="agent-error">{error}</div>)}

        {ack && (
          <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} className="glass mb-6 rounded-2xl p-5" data-testid="genie-plan">
            <div className="mb-2 flex items-center gap-2">
              <div className="glow-primary flex h-7 w-7 items-center justify-center rounded-lg bg-[#00FF9D] text-black"><Zap size={15} /></div>
              <h2 className="font-heading text-sm font-bold">Genie · Plan</h2>
            </div>
            <div className="text-[13px] text-zinc-300"><Markdown>{ack}</Markdown></div>
          </motion.div>
        )}

        {agents.length > 0 && (
          <>
            <div className="mb-4 flex items-center justify-between">
              <h2 className="font-mono text-[11px] uppercase tracking-[0.2em] text-zinc-500">Specialist Agents</h2>
              <div className="flex items-center gap-2">
                <button onClick={copyReport} data-testid="copy-report-btn"
                  className="inline-flex items-center gap-1.5 rounded-lg border border-white/10 bg-black/40 px-3 py-1.5 text-xs text-zinc-200 transition-colors hover:border-[#00FF9D]/50 hover:text-white">
                  {copied ? (<><ClipboardCheck size={13} className="text-[#00FF9D]" /> Copied</>) : (<><Copy size={13} /> Copy report</>)}
                </button>
                <button onClick={downloadReport} data-testid="download-report-btn"
                  className="inline-flex items-center gap-1.5 rounded-lg border border-white/10 bg-black/40 px-3 py-1.5 text-xs text-zinc-200 transition-colors hover:border-[#00FF9D]/50 hover:text-white">
                  <Download size={13} /> Download .md
                </button>
              </div>
            </div>
            <div className="mb-6 grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3">
              {agents.map((a, i) => (
                <AgentCard key={a.role} agent={a} index={i} expanded={!!expanded[a.role]}
                  onToggle={() => setExpanded((e) => ({ ...e, [a.role]: !e[a.role] }))} />
              ))}
            </div>
          </>
        )}

        {verdict && (
          <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }}
            className={`glass rounded-2xl border-l-4 p-5 ${verdictPass ? "border-l-[#00FF9D]" : "border-l-[#FFB020]"}`} data-testid="critic-verdict">
            <div className="mb-2 flex items-center gap-2">
              <Gavel size={16} className={verdictPass ? "text-[#00FF9D]" : "text-[#FFB020]"} />
              <h2 className="font-heading text-sm font-bold">QA Critic Verdict</h2>
            </div>
            <div className="text-[13px] text-zinc-200"><Markdown>{verdict}</Markdown></div>
          </motion.div>
        )}
      </div>
    </div>
  );
}
JSX_AGENT

cat <<'JSX_DASH' > frontend/src/components/DashboardMode.jsx
import { useState, useEffect } from "react";
import { motion } from "framer-motion";
import { Activity, Cpu, Boxes, Terminal, GitBranch, FolderTree, Rocket, Brain, LayoutDashboard, Server, ShieldCheck, PlayCircle, Loader2, CheckCircle2, XCircle, ChevronDown, Copy, ClipboardCheck } from "lucide-react";
import { api, errText, API } from "@/api";

const TREE = [
  { label: "Core Engine", icon: Cpu, depth: 0 },
  { label: "Agent System", icon: Boxes, depth: 0 },
  { label: "Planner", icon: Brain, depth: 1 },
  { label: "Coder", icon: Terminal, depth: 1 },
  { label: "Tester", icon: ShieldCheck, depth: 1 },
  { label: "Repair Agent", icon: Activity, depth: 1 },
  { label: "Interface", icon: LayoutDashboard, depth: 0 },
  { label: "Open WebUI", icon: Server, depth: 1 },
  { label: "Dashboard", icon: LayoutDashboard, depth: 1 },
  { label: "Model Gateway", icon: Cpu, depth: 0 },
  { label: "OpenRouter / OpenAI-compatible API", icon: Cpu, depth: 1 },
  { label: "Memory", icon: Brain, depth: 0 },
  { label: "Tools", icon: Boxes, depth: 0 },
  { label: "Terminal", icon: Terminal, depth: 1 },
  { label: "Git", icon: GitBranch, depth: 1 },
  { label: "File manager", icon: FolderTree, depth: 1 },
  { label: "Deployment", icon: Rocket, depth: 1 },
  { label: "Health System", icon: Activity, depth: 0 },
];

function StatDot({ ok }) {
  return (<span className={`h-2 w-2 shrink-0 rounded-full ${ok ? "bg-[#00FF9D] pulse-dot" : "bg-[#FF3366]"}`} />);
}

export default function DashboardMode({ hasKey }) {
  const [health, setHealth] = useState(null);
  const [loadingHealth, setLoadingHealth] = useState(true);
  const [proof, setProof] = useState(null);
  const [proving, setProving] = useState(false);
  const [error, setError] = useState("");
  const [openStep, setOpenStep] = useState(null);
  const [copied, setCopied] = useState(false);

  const gatewayBase = `${API}/v1`;

  const loadHealth = () => {
    setLoadingHealth(true);
    api.systemHealth().then(setHealth).catch(() => {}).finally(() => setLoadingHealth(false));
  };

  useEffect(() => { loadHealth(); }, []);

  const runProof = async () => {
    if (proving || !hasKey) return;
    setProving(true); setError(""); setProof(null);
    try {
      const res = await api.prove();
      setProof(res);
    } catch (e) {
      setError(errText(e));
    } finally {
      setProving(false);
    }
  };

  const copyBase = async () => {
    try { await navigator.clipboard.writeText(gatewayBase); setCopied(true); setTimeout(() => setCopied(false), 1500); } catch {}
  };

  return (
    <div className="h-full overflow-y-auto px-5 py-6" data-testid="dashboard-mode">
      <div className="mx-auto max-w-6xl">
        <div className="mb-1 font-mono text-[11px] uppercase tracking-[0.25em] text-[#00FF9D]">NOVA MASTER</div>
        <h1 className="mb-6 font-heading text-3xl font-extrabold">Control Dashboard</h1>

        <div className="grid grid-cols-1 gap-5 lg:grid-cols-3">
          <div className="glass rounded-2xl p-5 lg:row-span-2" data-testid="system-tree">
            <h2 className="mb-4 flex items-center gap-2 font-heading text-sm font-bold"><Boxes size={16} className="text-[#00FF9D]" /> System Map</h2>
            <div className="space-y-0.5">
              {TREE.map((n) => {
                const Icon = n.icon;
                return (
                  <div key={n.label} className={`flex items-center gap-2 rounded-md py-1.5 text-sm ${n.depth === 0 ? "text-white" : "text-zinc-400"}`} style={{ paddingLeft: `${n.depth * 18}px` }}>
                    {n.depth === 1 && <span className="font-mono text-zinc-700">└─</span>}
                    <Icon size={n.depth === 0 ? 15 : 13} className={n.depth === 0 ? "text-[#00E5FF]" : "text-zinc-500"} />
                    <span className={n.depth === 0 ? "font-medium" : "font-mono text-xs"}>{n.label}</span>
                  </div>
                );
              })}
            </div>
          </div>

          <div className="glass rounded-2xl p-5 lg:col-span-2" data-testid="health-panel">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="flex items-center gap-2 font-heading text-sm font-bold"><Activity size={16} className="text-[#00FF9D]" /> Health System</h2>
              {health && (<span className="font-mono text-xs text-[#00FF9D]">{health.healthy}/{health.total} healthy</span>)}
            </div>
            {loadingHealth ? (
              <div className="flex items-center gap-2 text-sm text-zinc-500"><Loader2 size={15} className="animate-spin" /> checking subsystems…</div>
            ) : (
              <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                {health?.checks?.map((c) => (
                  <div key={c.name} className="flex items-start gap-2.5 rounded-xl border border-white/5 bg-black/30 px-3 py-2.5" data-testid={`health-${c.name}`}>
                    <StatDot ok={c.ok} />
                    <div className="min-w-0">
                      <div className="text-sm text-zinc-100">{c.name}</div>
                      <div className="truncate font-mono text-[10px] text-zinc-500">{c.detail}</div>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>

          <div className="glass rounded-2xl p-5 lg:col-span-2" data-testid="gateway-panel">
            <h2 className="mb-3 flex items-center gap-2 font-heading text-sm font-bold"><Server size={16} className="text-[#00FF9D]" /> Model Gateway · Connect Open WebUI</h2>
            <p className="mb-3 text-sm text-zinc-400">NOVA exposes an OpenAI-compatible endpoint. Point Open WebUI (podman) at it — every model is a free OpenRouter model, no key in the browser.</p>
            <div className="mb-3 flex items-center gap-2 rounded-lg border border-white/10 bg-black/40 px-3 py-2">
              <span className="font-mono text-[10px] uppercase text-zinc-500">Base URL</span>
              <code className="flex-1 truncate font-mono text-xs text-[#00E5FF]">{gatewayBase}</code>
              <button onClick={copyBase} data-testid="copy-gateway-btn" className="rounded-md p-1 text-zinc-400 hover:text-white">
                {copied ? <ClipboardCheck size={14} className="text-[#00FF9D]" /> : <Copy size={14} />}
              </button>
            </div>
            <pre className="overflow-x-auto rounded-lg border border-white/10 bg-black/50 p-3 font-mono text-[11px] leading-relaxed text-zinc-300">
{`# deploy/open-webui/
NOVA_BASE_URL="${API.replace(/\/api$/, "")}" ./start.sh
# -> http://localhost:3080  (free models in the picker)`}
            </pre>
          </div>

          <div className="glass rounded-2xl p-5 lg:col-span-3" data-testid="prove-panel">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="flex items-center gap-2 font-heading text-sm font-bold"><PlayCircle size={16} className="text-[#00FF9D]" /> Phase 5 · Prove It</h2>
              <button onClick={runProof} disabled={proving || !hasKey} data-testid="run-proof-btn"
                className="glow-primary inline-flex items-center gap-2 rounded-xl bg-[#00FF9D] px-5 py-2.5 text-sm font-semibold text-black transition-transform hover:-translate-y-0.5 disabled:opacity-40 disabled:hover:translate-y-0">
                {proving ? <Loader2 size={16} className="animate-spin" /> : <PlayCircle size={16} />}
                {proving ? "Proving…" : "Run self-proof"}
              </button>
            </div>

            {error && (<div className="mb-3 text-sm text-[#FF3366]" data-testid="prove-error">{error}</div>)}

            {!proof && !proving && (
              <p className="text-sm text-zinc-500">Runs a live, sandboxed self-demonstration: reads its own repo, explains its architecture, modifies a test, runs it, reports the diff, restores from backup, and prepares deployment.</p>
            )}

            {proof && (
              <>
                <div className="mb-3 font-mono text-xs text-[#00FF9D]">{proof.passed}/{proof.total} checks passed · workspace {proof.workspace}</div>
                <div className="space-y-2">
                  {proof.steps.map((s, i) => (
                    <motion.div key={s.name} initial={{ opacity: 0, x: -8 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: i * 0.04 }}
                      className="rounded-xl border border-white/5 bg-black/30" data-testid={`prove-step-${i}`}>
                      <button onClick={() => setOpenStep(openStep === i ? null : i)} className="flex w-full items-center gap-3 px-4 py-3 text-left">
                        {s.ok ? (<CheckCircle2 size={17} className="text-[#00FF9D]" />) : (<XCircle size={17} className="text-[#FF3366]" />)}
                        <span className="flex-1 text-sm text-zinc-100">{s.name}</span>
                        <ChevronDown size={15} className={`text-zinc-500 transition-transform ${openStep === i ? "rotate-180" : ""}`} />
                      </button>
                      {openStep === i && (
                        <pre className="mx-4 mb-3 max-h-64 overflow-auto whitespace-pre-wrap rounded-lg border border-white/5 bg-black/50 p-3 font-mono text-[11px] leading-relaxed text-zinc-300">
                          {s.detail || "(no output)"}
                        </pre>
                      )}
                    </motion.div>
                  ))}
                </div>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
JSX_DASH

# ----------------------------------------------------------------------------
# DEPLOY · Open WebUI (podman)
# ----------------------------------------------------------------------------
cat <<'YML_COMPOSE' > deploy/open-webui/docker-compose.yml
version: "3.9"
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: nova-open-webui
    ports:
      - "3080:8080"
    environment:
      - OPENAI_API_BASE_URL=${NOVA_BASE_URL:-http://host.containers.internal:8001}/api/v1
      - OPENAI_API_KEY=nova-local
      - WEBUI_AUTH=False
      - ENABLE_OLLAMA_API=False
    volumes:
      - open-webui-data:/app/backend/data
    restart: unless-stopped
volumes:
  open-webui-data: {}
YML_COMPOSE

cat <<'SH_START' > deploy/open-webui/start.sh
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NOVA_BASE_URL="${NOVA_BASE_URL:-http://host.containers.internal:8001}"
echo "NOVA OpenAI-compatible endpoint: ${NOVA_BASE_URL}/api/v1"
if command -v podman-compose >/dev/null 2>&1; then RUNNER="podman-compose";
elif command -v podman >/dev/null 2>&1; then RUNNER="podman compose";
elif command -v docker >/dev/null 2>&1; then RUNNER="docker compose";
else echo "ERROR: install podman (recommended) or docker first." >&2; exit 1; fi
echo "Using: ${RUNNER}"
${RUNNER} -f "${HERE}/docker-compose.yml" up -d
echo "Open WebUI is starting -> http://localhost:3080"
SH_START
chmod +x deploy/open-webui/start.sh

cat <<'MD_DEPLOY' > deploy/open-webui/README.md
# Open WebUI + NOVA (free, sovereign)

Runs the real Open WebUI in podman, pointed at NOVA's OpenAI-compatible proxy.
Every model you pick is a free OpenRouter model; NOVA holds the key server-side.

## Launch
    ./start.sh
    # remote NOVA:  NOVA_BASE_URL="https://your-nova-backend" ./start.sh
Then open http://localhost:3080

## Manual connection (existing Open WebUI)
Settings -> Connections -> OpenAI API
  Base URL: {NOVA}/api/v1
  API Key:  any value (NOVA ignores it)
MD_DEPLOY

# ----------------------------------------------------------------------------
# TOP-LEVEL run.sh + README + .gitignore
# ----------------------------------------------------------------------------
cat <<'SH_RUN' > run.sh
#!/usr/bin/env bash
# NOVA MASTER — self-hosted launcher; API includes filesystem/shell/Git tools.
# Use loopback or a private Tailscale address only; public exposure requires auth.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIND_HOST="${NOVA_BIND_HOST:-127.0.0.1}"
if [[ -z "${NOVA_BIND_HOST:-}" ]] && command -v tailscale >/dev/null 2>&1; then
  candidate="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
  [[ "$candidate" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && BIND_HOST="$candidate"
fi
if [[ ! "$BIND_HOST" =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ && ! "$BIND_HOST" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "ERROR: bind host must be loopback or a Tailscale 100.64.0.0/10 address; refusing $BIND_HOST" >&2
  exit 1
fi

echo ">> 1/3  MongoDB (podman; loopback only)"
if command -v podman >/dev/null 2>&1; then
  if ! podman ps --format '{{.Names}}' | grep -q '^nova-mongo$'; then
    if podman ps -a --format '{{.Names}}' | grep -q '^nova-mongo$'; then
      podman start nova-mongo
    else
      podman run -d --name nova-mongo -p 127.0.0.1:27017:27017 docker.io/library/mongo:7
    fi
  fi
else
  echo "!! podman not found. Install it (sudo dnf install -y podman) or run MongoDB yourself on :27017"
fi

echo ">> 2/3  Backend (FastAPI :8001)"
cd "$ROOT/backend"
[ -d .venv ] || python3 -m venv .venv
source .venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt
export CORS_ORIGINS="${NOVA_SOVEREIGN_CORS_ORIGINS:-http://${BIND_HOST}:3000,http://127.0.0.1:3000,http://localhost:3000}"
uvicorn server:app --host "$BIND_HOST" --port 8001 > "$ROOT/backend/backend.log" 2>&1 &
BACK_PID=$!
echo "$BACK_PID" > "$ROOT/.backend.pid"
deactivate || true
echo "   backend pid $BACK_PID (logs: backend/backend.log)"

cleanup() { echo; echo ">> stopping backend"; kill "$BACK_PID" 2>/dev/null || true; exit 0; }
trap cleanup INT TERM

echo ">> 3/3  Frontend (Vite :3000)"
echo "   NOVA UI:  http://${BIND_HOST}:3000"
echo "   NOVA API: http://${BIND_HOST}:8001"
cd "$ROOT/frontend"
[ -d node_modules ] || npm install
export VITE_BACKEND_URL="${VITE_BACKEND_URL:-http://${BIND_HOST}:8001}"
npm run dev -- --host "$BIND_HOST" --port 3000
SH_RUN
chmod +x run.sh

cat <<'GITIGNORE' > .gitignore
**/__pycache__/
**/.venv/
**/node_modules/
**/build/
**/dist/
**/.env
!**/.env.example
**/*.log
**/.backend.pid
backend/agent_workspace/
GITIGNORE

cat <<'MD_README' > README.md
# NOVA MASTER — Sovereign AI

Free-first AI workspace. Chat + a self-organizing Agent Team + Dashboard,
using explicit OpenRouter `:free` model IDs or local Ollama; paid model overrides
and Google models are rejected. Front it with Open WebUI (podman) if you like.

**Security boundary:** this is a single-owner self-hosted control plane and includes
filesystem/shell/Git agent tools. Its API does not implement a general user login.
The launcher binds only to loopback or a private Tailscale address. Keep restrictive
tailnet ACLs and do not port-forward/publish it publicly until authenticated access
and least-privilege controls are implemented.

## Architecture
    podman Open WebUI -> OpenAI-compatible API -> OpenRouter proxy (free)
                       -> Agent Runtime -> Files / Shell / Git

## Prerequisites (Fedora)
    sudo dnf install -y python3 python3-pip nodejs git podman
    # Vite 8 needs Node 20.19+ or 22.12+; Node 22.12+ recommended.

## Setup
1. Optionally add an OpenRouter key in backend/.env (`OPENROUTER_API_KEY`). NOVA only sends requests to model IDs ending in `:free`; without a key it uses local Ollama.
2. Launch everything:
       ./run.sh
3. Open the UI address printed by `run.sh`. With Tailscale it uses the private Tailscale IPv4 address; otherwise it uses loopback.

## Optional: Open WebUI
    cd deploy/open-webui && ./start.sh   # -> http://localhost:3080

## Ports
- Frontend  `http://<BIND_HOST>:3000` (private loopback/Tailscale)
- Backend   `http://<BIND_HOST>:8001` (OpenAI-compatible at /api/v1; private loopback/Tailscale)
- MongoDB   `127.0.0.1:27017` (podman container nova-mongo)
MD_README

# ----------------------------------------------------------------------------
echo ""
echo "=============================================================="
echo "  NOVA MASTER generated in ./$ROOT"
echo "=============================================================="
echo "  1) Add your free OpenRouter key:"
echo "       \$EDITOR $ROOT/backend/.env      (OPENROUTER_API_KEY=...)"
echo "     Get one: https://openrouter.ai/keys"
echo "     Enable free models: https://openrouter.ai/settings/privacy"
echo ""
echo "  2) Prereqs (once):"
echo "       sudo dnf install -y python3 python3-pip nodejs git podman"
echo ""
echo "  3) Run it:"
echo "       cd $ROOT && ./run.sh"
echo "       -> ./run.sh prints the correct loopback/Tailscale UI URL"
echo ""
echo "  Optional Open WebUI front-end:"
echo "       cd $ROOT/deploy/open-webui && ./start.sh   (-> :3080)"
echo "=============================================================="
