"""Tiny JSONL append-only stores. Keeps recruiter state crash-safe and greppable.

Optional Mongo is left unimplemented on purpose: JSONL is the source of truth
until the worker scales, at which point a store adapter can be swapped in.
"""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Dict, Generator, List, Optional


class JsonlStore:
    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def append(self, record: Dict[str, Any]) -> None:
        with self.path.open("a") as fh:
            fh.write(json.dumps(record, sort_keys=True) + "\n")

    def rows(self) -> Generator[Dict[str, Any], None, None]:
        if not self.path.exists():
            return
        with self.path.open() as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue

    def all(self) -> List[Dict[str, Any]]:
        return list(self.rows())

    def where(self, pred) -> List[Dict[str, Any]]:
        return [r for r in self.rows() if pred(r)]

    def count(self) -> int:
        return sum(1 for _ in self.rows())

    def clear(self) -> None:
        self.path.unlink(missing_ok=True)


def now_iso() -> str:
    import datetime as _dt

    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")


def now_epoch() -> float:
    return time.time()