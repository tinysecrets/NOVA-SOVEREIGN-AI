"""Regression tests for NOVA's hard $0 / no-Google model policy.

These tests compile the actual policy functions from server.py without importing
its database/network application dependencies.
"""
from __future__ import annotations

import ast
import unittest
from pathlib import Path
from typing import Optional

BACKEND = Path(__file__).resolve().parents[1]
SERVER_SOURCE = BACKEND / "server.py"
SAFE_FALLBACK = "nvidia/nemotron-3.5-lightning:free"


def load_policy_functions():
    tree = ast.parse(SERVER_SOURCE.read_text(encoding="utf-8"), filename=str(SERVER_SOURCE))
    wanted = {"_is_safe_free_model", "_safe_free_model", "_enforce_free", "_explicit_cors_origins"}
    defs = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in wanted]
    assignments = [
        node for node in tree.body
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "SAFE_FREE_MODEL" for target in node.targets)
    ]
    if len(defs) != len(wanted) or len(assignments) != 1:
        raise AssertionError("server.py must contain the complete central model-policy gate")
    module = ast.Module(body=assignments + defs, type_ignores=[])
    namespace = {"Optional": Optional, "DEFAULT_MODEL": SAFE_FALLBACK}
    exec(compile(ast.fix_missing_locations(module), str(SERVER_SOURCE), "exec"), namespace)
    return namespace


class ModelPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy = load_policy_functions()

    def test_default_is_explicit_free_non_google_model(self):
        self.assertEqual(self.policy["SAFE_FREE_MODEL"], SAFE_FALLBACK)
        self.assertTrue(self.policy["_is_safe_free_model"](SAFE_FALLBACK))

    def test_cors_origins_require_an_explicit_non_wildcard_allowlist(self):
        validator = self.policy["_explicit_cors_origins"]
        self.assertEqual(
            validator("http://127.0.0.1:3000, http://localhost:3000"),
            ["http://127.0.0.1:3000", "http://localhost:3000"],
        )
        for value in ("*", "", " , "):
            with self.subTest(value=value):
                with self.assertRaises(RuntimeError):
                    validator(value)

    def test_paid_or_unpriced_model_is_never_accepted(self):
        for model in ("nousresearch/hermes-4-70b", "openai/gpt-4.1", "openrouter/free", ""):
            with self.subTest(model=model):
                self.assertFalse(self.policy["_is_safe_free_model"](model))
                self.assertEqual(self.policy["_safe_free_model"](model, SAFE_FALLBACK), SAFE_FALLBACK)
                self.assertEqual(self.policy["_enforce_free"](model, SAFE_FALLBACK), SAFE_FALLBACK)

    def test_google_models_are_excluded_even_when_marked_free(self):
        for model in ("google/gemma-4-31b-it:free", "Google/some-model:free"):
            with self.subTest(model=model):
                self.assertFalse(self.policy["_is_safe_free_model"](model))
                self.assertEqual(self.policy["_safe_free_model"](model, SAFE_FALLBACK), SAFE_FALLBACK)

    def test_explicit_non_google_free_model_is_allowed(self):
        model = "meta-llama/llama-3.2-3b-instruct:free"
        self.assertTrue(self.policy["_is_safe_free_model"](model))
        self.assertEqual(self.policy["_enforce_free"](model, SAFE_FALLBACK), model)

    def test_generator_keeps_the_same_free_fallback_and_google_filter(self):
        script = (BACKEND.parents[3] / "scripts" / "setup" / "build_nova.sh").read_text(encoding="utf-8")
        self.assertIn('SAFE_FREE_MODEL = "nvidia/nemotron-3.5-lightning:free"', script)
        self.assertIn('not mid.lower().startswith("google/")', script)
        self.assertIn("return _safe_free_model(model, _safe_free_model(fallback, DEFAULT_MODEL))", script)


if __name__ == "__main__":
    unittest.main()
