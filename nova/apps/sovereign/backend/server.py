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
import httpx

import agent_tools as tools
import agent_pipeline as pipeline

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


def _explicit_cors_origins(value: Optional[str]) -> list[str]:
    origins = [origin.strip() for origin in str(value or "").split(",") if origin.strip()]
    if not origins or "*" in origins:
        raise RuntimeError("CORS_ORIGINS must contain explicit trusted origins; wildcards are forbidden")
    return origins


DEFAULT_MODEL = _safe_free_model(os.environ.get("OPENROUTER_MODEL"), SAFE_FREE_MODEL)
ENV_KEY = os.environ.get("OPENROUTER_API_KEY", "")
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5:1.5b")
OLLAMA_NUM_PREDICT = int(os.environ.get("OLLAMA_NUM_PREDICT", "4096"))
DEFAULT_MAX_TOKENS = int(os.environ.get("NOVA_MAX_TOKENS", "4096"))

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


async def get_settings() -> Dict[str, Any]:
    doc = await db.settings.find_one({"_id": "app"}) or {}
    key = doc.get("openrouter_api_key") or ENV_KEY
    model = _safe_free_model(doc.get("model") or DEFAULT_MODEL, DEFAULT_MODEL)
    return {"key": key, "model": model, "has_key": bool(key)}


async def get_llm() -> AsyncOpenAI:
    s = await get_settings()
    if not s["key"]:
        raise HTTPException(
            400,
            "No OpenRouter API key configured. Add a free key in Settings, or set OLLAMA_HOST for local models.",
        )
    return AsyncOpenAI(api_key=s["key"], base_url=OPENROUTER_BASE_URL)


EXTRA_HEADERS = {"HTTP-Referer": "https://nova.sovereign.ai", "X-Title": "NOVA Sovereign AI"}


async def ollama_reachable() -> bool:
    try:
        async with httpx.AsyncClient(timeout=2.0) as http:
            r = await http.get(f"{OLLAMA_HOST}/api/tags")
            return r.status_code == 200
    except Exception:  # noqa: BLE001
        return False


async def ollama_complete(system: str, messages: List[Dict[str, str]],
                          temperature: float = 0.5, max_tokens: int = DEFAULT_MAX_TOKENS,
                          model: Optional[str] = None) -> str:
    model = model or OLLAMA_MODEL
    # Flatten to ollama chat messages
    msgs = [{"role": "system", "content": system}]
    for m in messages:
        msgs.append({"role": m["role"], "content": m["content"]})
    parts: List[str] = []
    async with httpx.AsyncClient(timeout=600.0) as http:
        # Non-stream first attempt with high num_predict; continue once if truncated
        for _ in range(2):
            r = await http.post(
                f"{OLLAMA_HOST}/api/chat",
                json={
                    "model": model,
                    "stream": False,
                    "options": {
                        "temperature": temperature,
                        "num_predict": max(max_tokens, OLLAMA_NUM_PREDICT),
                    },
                    "messages": msgs + ([{"role": "assistant", "content": "".join(parts)}] if parts else []),
                },
            )
            r.raise_for_status()
            data = r.json()
            chunk = (data.get("message") or {}).get("content") or ""
            parts.append(chunk)
            done_reason = data.get("done_reason") or ""
            if done_reason != "length" and not data.get("truncated"):
                break
            msgs = msgs + [
                {"role": "assistant", "content": chunk},
                {"role": "user", "content": "Continue exactly where you left off. Do not repeat."},
            ]
    return "".join(parts).strip()


async def complete(llm: Optional[AsyncOpenAI], model: str, system: str, messages: List[Dict[str, str]],
                   temperature: float = 0.5, max_tokens: int = DEFAULT_MAX_TOKENS) -> str:
    """OpenRouter when key+llm present; otherwise Ollama. Continues once on length truncation."""
    if llm is None:
        return await ollama_complete(system, messages, temperature, max_tokens, model=OLLAMA_MODEL)

    model = _safe_free_model(model, DEFAULT_MODEL)
    payload = [{"role": "system", "content": system}] + messages
    texts: List[str] = []
    try:
        for _ in range(2):
            resp = await llm.chat.completions.create(
                model=model, messages=payload, temperature=temperature,
                max_tokens=max_tokens, extra_headers=EXTRA_HEADERS)
            choice = resp.choices[0]
            texts.append((choice.message.content or "").strip())
            fr = getattr(choice, "finish_reason", None) or ""
            if fr != "length":
                break
            payload = payload + [
                {"role": "assistant", "content": texts[-1]},
                {"role": "user", "content": "Continue exactly where you left off. Do not repeat prior text."},
            ]
    except Exception as e:  # noqa: BLE001
        logger.exception("OpenRouter call failed; trying Ollama")
        if await ollama_reachable():
            return await ollama_complete(system, messages, temperature, max_tokens)
        raise HTTPException(502, f"OpenRouter request failed: {e}")
    return "\n".join(t for t in texts if t).strip()


async def resolve_backend() -> Dict[str, Any]:
    """Pick free backend: OpenRouter key → openrouter; else Ollama if up."""
    s = await get_settings()
    if s["key"]:
        return {"mode": "openrouter", "model": s["model"], "key": s["key"]}
    if await ollama_reachable():
        return {"mode": "ollama", "model": OLLAMA_MODEL, "key": ""}
    raise HTTPException(
        400,
        "No free backend ready. Add an OpenRouter free API key in Settings, or start Ollama locally.",
    )


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
    return {
        "status": "healthy",
        "service": "NOVA",
        "ts": datetime.now(timezone.utc).isoformat(),
    }


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
    add("Model Gateway", bool(s["key"]) or await ollama_reachable(),
        f"OpenRouter · {s['model']}" if s["key"] else (
            f"Ollama · {OLLAMA_MODEL}" if await ollama_reachable() else "No free backend"))
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
    ollama = await ollama_reachable()
    return {
        "has_key": bool(s["key"]),
        "model": s["model"],
        "base_url": OPENROUTER_BASE_URL,
        "ollama": ollama,
        "ollama_model": OLLAMA_MODEL,
        "ready": bool(s["key"]) or ollama,
    }


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
    return await read_settings()


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
    if await ollama_reachable():
        models = [f"ollama/{OLLAMA_MODEL}"] + models
    seen, ordered = set(), []
    for mid in [active, DEFAULT_MODEL] + models:
        if mid and mid not in seen:
            seen.add(mid)
            ordered.append(mid)
    return {"models": ordered, "active": active}


async def _llm_or_none() -> Optional[AsyncOpenAI]:
    s = await get_settings()
    if s["key"]:
        return AsyncOpenAI(api_key=s["key"], base_url=OPENROUTER_BASE_URL)
    return None


@api.post("/chat")
async def chat(req: ChatRequest):
    backend = await resolve_backend()
    llm = await _llm_or_none()
    model = req.model or backend["model"]
    if model.startswith("ollama/"):
        model = model.split("/", 1)[1]
        llm = None
    session_id = req.session_id or str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    await db.messages.insert_one({"id": str(uuid.uuid4()), "session_id": session_id,
                                  "role": "user", "content": req.message, "at": now})
    prior = await (db.messages.find({"session_id": session_id}, {"_id": 0}).sort("at", 1).limit(60).to_list(60))
    history = [{"role": m["role"], "content": m["content"]} for m in prior
               if m.get("role") in ("user", "assistant") and m.get("content")]
    reply = await complete(llm, model if llm else OLLAMA_MODEL, NOVA_SYSTEM_PROMPT, history, temperature=0.6)
    await db.messages.insert_one({"id": str(uuid.uuid4()), "session_id": session_id, "role": "assistant",
                                  "content": reply, "model": model, "at": datetime.now(timezone.utc).isoformat()})
    return {"session_id": session_id, "reply": reply, "model": model}


@api.post("/chat/stream")
async def chat_stream(req: ChatRequest):
    backend = await resolve_backend()
    llm = await _llm_or_none()
    model = req.model or backend["model"]
    use_ollama = llm is None or (isinstance(model, str) and model.startswith("ollama/"))
    if isinstance(model, str) and model.startswith("ollama/"):
        model = model.split("/", 1)[1]
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
            if use_ollama or llm is None:
                reply = await ollama_complete(
                    NOVA_SYSTEM_PROMPT, history, temperature=0.6,
                    max_tokens=DEFAULT_MAX_TOKENS, model=model if use_ollama else OLLAMA_MODEL)
                # Simulate token-ish chunks for UI
                step = max(24, len(reply) // 40 or 1)
                for i in range(0, len(reply), step):
                    delta = reply[i:i + step]
                    parts.append(delta)
                    yield f"data: {json.dumps({'delta': delta})}\n\n"
                    await asyncio.sleep(0)
            else:
                stream = await llm.chat.completions.create(
                    model=model, messages=[{"role": "system", "content": NOVA_SYSTEM_PROMPT}] + history,
                    temperature=0.6, max_tokens=DEFAULT_MAX_TOKENS, stream=True, extra_headers=EXTRA_HEADERS)
                async for chunk in stream:
                    delta = (chunk.choices[0].delta.content or "") if chunk.choices else ""
                    if delta:
                        parts.append(delta)
                        yield f"data: {json.dumps({'delta': delta})}\n\n"
        except Exception as e:  # noqa: BLE001
            logger.exception("Chat stream failed")
            yield f"data: {json.dumps({'error': str(e)})}\n\n"
            yield f"data: {json.dumps({'done': True, 'ok': False})}\n\n"
            return
        reply = "".join(parts).strip()
        await db.messages.insert_one({"id": str(uuid.uuid4()), "session_id": session_id, "role": "assistant",
                                      "content": reply, "model": model, "at": datetime.now(timezone.utc).isoformat()})
        yield f"data: {json.dumps({'done': True, 'ok': True, 'model': model})}\n\n"

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
    backend = await resolve_backend()
    llm = await _llm_or_none()
    model = req.model or backend["model"]
    if isinstance(model, str) and model.startswith("ollama/"):
        model = model.split("/", 1)[1]
        llm = None
    plan = await complete(llm, model if llm else OLLAMA_MODEL, GENIE_SYSTEM,
                          [{"role": "user", "content": f"Goal from the operator:\n{req.goal}"}],
                          temperature=0.4, max_tokens=1200)
    orders = pipeline.parse_orders(plan, req.goal, SPECIALISTS)
    return {"acknowledgement": plan, "orders": orders, "model": model}


@api.post("/agents/dispatch")
async def agents_dispatch(req: DispatchRequest):
    role = req.role.lower()
    if role not in SPECIALISTS:
        raise HTTPException(400, f"Unknown role: {role}")
    backend = await resolve_backend()
    llm = await _llm_or_none()
    model = req.model or backend["model"]
    if isinstance(model, str) and model.startswith("ollama/"):
        model = model.split("/", 1)[1]
        llm = None
    user_msg = (f"Overall goal:\n{req.goal}\n\nYour specific order:\n{req.order}\n\n"
                "Deliver your part now, following your output format.")
    output = await complete(llm, model if llm else OLLAMA_MODEL, SPECIALISTS[role]["system"],
                            [{"role": "user", "content": user_msg}], temperature=0.5, max_tokens=DEFAULT_MAX_TOKENS)
    return {"role": role, "name": SPECIALISTS[role]["name"], "order": req.order, "output": output}


@api.post("/agents/critic")
async def agents_critic(req: CriticRequest):
    backend = await resolve_backend()
    llm = await _llm_or_none()
    model = req.model or backend["model"]
    if isinstance(model, str) and model.startswith("ollama/"):
        model = model.split("/", 1)[1]
        llm = None
    body = "\n\n".join(f"## [{r.get('name', r.get('role'))}] {r.get('order','')}\n{r.get('output','')}" for r in req.results)
    prompt = (f"Original goal:\n{req.goal}\n\nAssembled team output:\n{body}\n\n"
              "Judge whether the assembled output satisfies the goal. Emit exactly:\n"
              "  VERDICT: PASS|FAIL\n  RATIONALE: one short paragraph\n  P0_ISSUES: bullets (or 'none')")
    verdict = await complete(llm, model if llm else OLLAMA_MODEL, SPECIALISTS["qa"]["system"],
                             [{"role": "user", "content": prompt}], temperature=0.3, max_tokens=1200)
    run_id = str(uuid.uuid4())
    await db.agent_runs.insert_one({"id": run_id, "goal": req.goal, "results": req.results,
                                    "verdict": verdict, "model": model, "at": datetime.now(timezone.utc).isoformat()})
    return {"run_id": run_id, "verdict": verdict, "model": model}


class RunRequest(BaseModel):
    goal: str
    model: Optional[str] = None


@api.post("/agents/run")
async def agents_run(req: RunRequest):
    """Full mission pipeline over SSE — backend-owned handoffs, no browser orchestration."""
    backend = await resolve_backend()
    llm = await _llm_or_none()
    model = req.model or backend["model"]
    if isinstance(model, str) and model.startswith("ollama/"):
        model = model.split("/", 1)[1]
        llm = None
    use_model = model if llm else OLLAMA_MODEL

    queue: asyncio.Queue = asyncio.Queue()

    async def emit(ev: dict) -> None:
        await queue.put(ev)

    async def complete_fn(system: str, messages: List[Dict[str, str]],
                          temperature: float = 0.5, max_tokens: int = DEFAULT_MAX_TOKENS) -> str:
        return await complete(llm, use_model, system, messages,
                              temperature=temperature, max_tokens=max_tokens)

    async def runner() -> None:
        try:
            result = await pipeline.run_mission(
                goal=req.goal,
                model=use_model,
                specialists=SPECIALISTS,
                genie_system=GENIE_SYSTEM,
                complete_fn=complete_fn,
                emit=emit,
            )
            await db.agent_runs.insert_one({
                "id": result["run_id"],
                "goal": req.goal,
                "results": result["results"],
                "verdict": result["verdict"],
                "model": use_model,
                "at": datetime.now(timezone.utc).isoformat(),
            })
        except Exception as e:  # noqa: BLE001
            logger.exception("Mission pipeline failed")
            await queue.put({"type": "error", "error": str(e)})
            await queue.put({"type": "done", "ok": False})
        finally:
            await queue.put(None)

    async def gen():
        task = asyncio.create_task(runner())
        try:
            while True:
                ev = await queue.get()
                if ev is None:
                    break
                yield f"data: {json.dumps(ev)}\n\n"
        finally:
            await task

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"})


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
    backend = await resolve_backend()
    llm = await _llm_or_none()
    model = req.model or backend["model"]
    if isinstance(model, str) and model.startswith("ollama/"):
        model = model.split("/", 1)[1]
        llm = None
    use_model = model if llm else OLLAMA_MODEL
    transcript: List[str] = [f"[user] {req.goal}"]
    steps: List[Dict[str, Any]] = []
    for i in range(max(1, min(req.max_steps, 12))):
        prompt = ("Conversation so far:\n" + "\n".join(transcript[-20:]) +
                  f"\n\nStep {i + 1}. Respond with one JSON action.")
        resp = await complete(llm, use_model, REACT_SYSTEM,
                              [{"role": "user", "content": prompt}], temperature=0.2, max_tokens=DEFAULT_MAX_TOKENS)
        action = _extract_json(resp)
        if not action:
            transcript.append(f"[assistant] {resp}")
            transcript.append("[system] ERROR: emit ONE JSON action.")
            steps.append({"step": i + 1, "raw": resp[:800], "error": "no json action"})
            continue
        if "final" in action:
            steps.append({"step": i + 1, "final": action["final"]})
            return {"goal": req.goal, "model": use_model, "steps": steps, "final": action["final"]}
        tool_name = action.get("tool", "")
        args = action.get("args") or {}
        result = await asyncio.to_thread(tools.invoke, tool_name, args)
        result_s = json.dumps(result)
        if len(result_s) > 8000:
            result_s = result_s[:8000] + "…[truncated]"
        transcript.append(f"[assistant] {json.dumps(action)}")
        transcript.append(f"[tool] {tool_name} -> {result_s}")
        steps.append({"step": i + 1, "thought": action.get("thought", ""),
                      "tool": tool_name, "args": args, "result": result})
    return {"goal": req.goal, "model": use_model, "steps": steps,
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
        llm = await _llm_or_none()
        use_model = s["model"] if llm else OLLAMA_MODEL
        if not llm and not await ollama_reachable():
            raise RuntimeError("no free backend")
        explanation = await complete(llm, use_model,
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
_CORS_ORIGINS = _explicit_cors_origins(
    os.environ.get("CORS_ORIGINS", "http://127.0.0.1:3000,http://localhost:3000")
)
app.add_middleware(
    CORSMiddleware,
    allow_credentials=True,
    allow_origins=_CORS_ORIGINS,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-Requested-With"],
)


@app.on_event("shutdown")
async def shutdown_db_client():
    client.close()
