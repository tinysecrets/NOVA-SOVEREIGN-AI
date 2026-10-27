"""Offline regression checks for Core routes, inference defaults, and request guards."""
from __future__ import annotations

import importlib.util
import sys
import types
from pathlib import Path

from fastapi.testclient import TestClient


def test_core_api_is_registered_local_first_and_rejects_untrusted_origins(monkeypatch):
    """Exercise the ASGI app with a fake Motor client; never connect to MongoDB."""
    backend_dir = Path(__file__).resolve().parents[1]
    monkeypatch.setenv("PYTHON_DOTENV_DISABLED", "1")
    monkeypatch.setenv("MONGO_URL", "mongodb://127.0.0.1:27017")
    monkeypatch.setenv("DB_NAME", "nova_unit_test_only")
    monkeypatch.setenv("OLLAMA_MODEL", "hermes3:8b")
    monkeypatch.setenv(
        "CORS_ORIGINS",
        "http://127.0.0.1:3002,http://localhost:3002",
    )

    motor_module = types.ModuleType("motor")
    motor_asyncio_module = types.ModuleType("motor.motor_asyncio")

    class FakeMotorClient:
        def __init__(self, *args, **kwargs):
            self.closed = False

        def __getitem__(self, _name):
            return object()

        def close(self):
            self.closed = True

    motor_asyncio_module.AsyncIOMotorClient = FakeMotorClient
    monkeypatch.setitem(sys.modules, "motor", motor_module)
    monkeypatch.setitem(sys.modules, "motor.motor_asyncio", motor_asyncio_module)

    spec = importlib.util.spec_from_file_location(
        "_nova_core_server_offline_test", backend_dir / "server.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    monkeypatch.setitem(sys.modules, spec.name, module)
    spec.loader.exec_module(module)

    required_routes = {
        ("GET", "/api/health"),
        ("POST", "/api/chat"),
        ("POST", "/api/chat/stream"),
        ("GET", "/api/memory"),
        ("POST", "/api/memory"),
        ("PATCH", "/api/memory/{mem_id}"),
        ("DELETE", "/api/memory/{mem_id}"),
        ("GET", "/api/settings/persona"),
        ("PUT", "/api/settings/persona"),
    }
    registered_routes = {
        (method, route.path)
        for route in module.app.routes
        if hasattr(route, "methods")
        for method in route.methods
    }
    assert required_routes <= registered_routes

    with TestClient(module.app) as client:
        health = client.get("/api/health")
        assert health.status_code == 200
        assert health.json() == {"status": "ok", "model": "hermes3:8b"}

        hostile_origin = client.post(
            "/api/chat",
            json={"message": "test"},
            headers={"Origin": "https://untrusted.example"},
        )
        assert hostile_origin.status_code == 403

        missing_auth = client.post(
            "/api/chat",
            json={"message": "test"},
            headers={"Origin": "http://127.0.0.1:3002"},
        )
        assert missing_auth.status_code == 401

        hostile_auth_origin = client.post(
            "/api/auth/session",
            json={"session_id": "not-a-real-session"},
            headers={"Origin": "https://untrusted.example"},
        )
        assert hostile_auth_origin.status_code == 403
