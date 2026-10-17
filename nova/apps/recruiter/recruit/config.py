"""Configuration loading for the recruiter worker.

Sources (later wins):
  1. config/recruiter.yaml  (policies, safe defaults)
  2. environment variables  (secrets, identity, send controls)
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List

import yaml


# Recruiter inference is hard $0: remote model IDs must explicitly advertise
# the OpenRouter free tier. Invalid/paid/Google overrides fall back to this model.
FREE_ROUTER_MODEL = "nvidia/nemotron-3.5-lightning:free"


def _safe_free_model(value: str, fallback: str = FREE_ROUTER_MODEL) -> str:
    model = str(value or "").strip()
    lowered = model.lower()
    if lowered.endswith(":free") and not lowered.startswith("google/"):
        return model
    return fallback


def _root() -> Path:
    here = Path(__file__).resolve()
    for cand in (
        os.environ.get("RECRUITER_ROOT"),
        here.parent.parent,              # apps/recruiter
        here.parent.parent.parent,       # nova/apps/recruiter (same thing) fallback
    ):
        if cand and Path(cand).exists():
            return Path(cand)
    return here.parent.parent


def _env_bool(env: Dict[str, str], name: str, default: bool = False) -> bool:
    raw = env.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _parse_env_file(path: Path) -> Dict[str, str]:
    out: Dict[str, str] = {}
    if not path.exists():
        return out
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        if key:
            out[key] = val
    return out


@dataclass
class RecruiterConfig:
    root: Path
    data_dir: Path
    yaml: Dict[str, Any]
    env: Dict[str, str]

    bot_email: str = "ember@wah-lah.com"
    bot_name: str = "Ember"
    boss_email: str = "jrs092393@gmail.com"
    resend_api_key: str = ""

    openrouter_api_key: str = ""
    openrouter_base: str = "https://openrouter.ai/api/v1"
    model_routine: str = FREE_ROUTER_MODEL
    model_high: str = FREE_ROUTER_MODEL
    ollama_base: str = "http://127.0.0.1:11434"
    ollama_model: str = "hermes3:8b"
    ollama_api_key: str = ""
    ollama_cloud_base: str = "https://ollama.com"
    ollama_cloud_model: str = "gpt-oss:20b"
    host: str = "127.0.0.1"
    port: int = 8003

    dry_run: bool = True
    approval_gate: bool = True
    daily_cap: int = 50
    max_per_hour: int = 15
    heartbeat_sec: int = 3600

    discord_token: str = ""
    discord_invite_url: str = ""
    telegram_token: str = ""
    telegram_chat_id: str = ""
    telegram_invite_url: str = ""

    url_app: str = "https://app.wah-lah.com"
    url_home: str = "https://wah-lah.com"

    postal_address: str = ""

    @property
    def socials(self) -> List[str]:
        return list(self.yaml.get("traffic", {}).get("socials", []))

    @property
    def channels_enabled(self) -> Dict[str, Dict[str, Any]]:
        out: Dict[str, Dict[str, Any]] = {}
        for name, spec in self.yaml.get("channel", {}).items():
            if spec.get("enabled"):
                out[name] = spec
        return out

    @property
    def banned_patterns(self) -> List[str]:
        return list(self.yaml.get("compliance", {}).get("banned_patterns", []))

    @property
    def banned_subject_patterns(self) -> List[str]:
        return list(self.yaml.get("compliance", {}).get("banned_subject_patterns", []))

    def model_for(self, *, high: bool = False) -> str:
        # Env overrides cannot silently unlock a paid model or Google route.
        configured = self.env.get("OPENROUTER_MODEL_HIGH", self.model_high) if high else self.env.get("OPENROUTER_MODEL", self.model_routine)
        return _safe_free_model(configured)

    @property
    def brain(self) -> Dict[str, str]:
        choice = (self.env.get("RECRUITER_BRAIN") or "auto").strip().lower()
        if choice == "openrouter" and self.openrouter_api_key:
            return {"provider": "openrouter", "model": self.model_for()}
        # The recruiter never calls metered cloud endpoints; Ollama stays local.
        if choice in {"ollama_cloud", "ollama_local"}:
            return {"provider": "ollama_local", "model": self.ollama_model}
        if self.openrouter_api_key:
            return {"provider": "openrouter", "model": self.model_for()}
        return {"provider": "ollama_local", "model": self.ollama_model}


def load_config() -> RecruiterConfig:
    root = _root()
    cfg_path = root / "config" / "recruiter.yaml"
    yaml_conf: Dict[str, Any] = {}
    if cfg_path.exists():
        yaml_conf = yaml.safe_load(cfg_path.read_text()) or {}

    env = {**_parse_env_file(root / ".env"), **dict(os.environ)}
    data_dir = Path(env.get("RECRUITER_DATA_DIR", str(root / "data"))).expanduser()
    data_dir.mkdir(parents=True, exist_ok=True)

    def ev_env(n: str, default: str = "") -> str:
        return env.get(n, default)

    conf = RecruiterConfig(
        root=root,
        data_dir=data_dir.resolve(),
        yaml=yaml_conf,
        env=env,
        bot_email=ev_env("BOT_EMAIL", "ember@wah-lah.com"),
        bot_name=ev_env("BOT_NAME", "Ember"),
        boss_email=ev_env("BOSS_EMAIL", "owner@example.com"),
        resend_api_key=ev_env("RESEND_API_KEY"),
        openrouter_api_key=ev_env("OPENROUTER_API_KEY"),
        openrouter_base=ev_env("OPENROUTER_BASE", "https://openrouter.ai/api/v1"),
        model_routine=_safe_free_model(ev_env("OPENROUTER_MODEL", FREE_ROUTER_MODEL)),
        model_high=_safe_free_model(ev_env("OPENROUTER_MODEL_HIGH", FREE_ROUTER_MODEL)),
        ollama_base=ev_env("OLLAMA_BASE_URL", "http://127.0.0.1:11434"),
        ollama_model=ev_env("OLLAMA_MODEL", "hermes3:8b"),
        ollama_api_key=ev_env("OLLAMA_API_KEY"),
        ollama_cloud_base=ev_env("OLLAMA_CLOUD_BASE", "https://ollama.com"),
        ollama_cloud_model=ev_env("OLLAMA_CLOUD_MODEL", "gpt-oss:20b"),
        host=ev_env("RECRUITER_HOST", "127.0.0.1"),
        port=int(env.get("RECRUITER_PORT", "8003")),
        dry_run=_env_bool(env, "RECRUITER_DRY_RUN", True),
        approval_gate=_env_bool(env, "RECRUITER_APPROVAL_GATE", True),
        daily_cap=int(env.get("RECRUITER_DAILY_CAP", yaml_conf.get("schedule", {}).get("daily_cap", 50))),
        max_per_hour=int(env.get("RECRUITER_MAX_PER_HOUR", yaml_conf.get("schedule", {}).get("max_per_hour", 15))),
        heartbeat_sec=int(env.get("RECRUITER_HEARTBEAT_SEC", yaml_conf.get("schedule", {}).get("heartbeat_sec", 3600))),
        discord_token=ev_env("DISCORD_BOT_TOKEN"),
        discord_invite_url=ev_env("DISCORD_INVITE_URL"),
        telegram_token=ev_env("TELEGRAM_BOT_TOKEN"),
        telegram_chat_id=ev_env("TELEGRAM_CHAT_ID"),
        telegram_invite_url=ev_env("TELEGRAM_INVITE_URL"),
        url_app=ev_env("URL_APP", str(yaml_conf.get("traffic", {}).get("app", "https://app.wah-lah.com"))),
        url_home=ev_env("URL_HOME", str(yaml_conf.get("traffic", {}).get("home", "https://wah-lah.com"))),
        postal_address=ev_env("POSTAL_ADDRESS", str(yaml_conf.get("compliance", {}).get("postal_address", ""))),
    )
    return conf