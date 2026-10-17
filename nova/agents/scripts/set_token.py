"""
scripts/set_token.py
====================
Store an explicitly opted-in free-tier provider token inside the encrypted
vault, alongside the derived keys. The vault file is the only place these tokens
ever live — never committed, never logged. Google/Gemini is not a supported route.

Usage:
    python scripts/set_token.py OPENROUTER_API_KEY
    # then paste the token at the prompt; NOVA uses only models ending in :free
"""
from __future__ import annotations

import argparse
import getpass
import json
import os
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: E402

from keys.key_manager import (  # noqa: E402
    VAULT_FILE,
    load_salt,
    open_vault,
    super_key_to_vault_key,
)

VALID = {"GROQ_API_KEY", "HF_TOKEN", "OPENROUTER_API_KEY"}


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("name", choices=sorted(VALID))
    args = p.parse_args()

    pw = os.environ.get("SUPER_KEY") or getpass.getpass("Super Key: ")
    token = os.environ.get(args.name) or getpass.getpass(f"Paste {args.name}: ")

    salt = load_salt()
    vault_key = super_key_to_vault_key(pw, salt)
    bundle = open_vault(vault_key)

    # We store the token by re-sealing the vault with an extra "env" map.
    # `to_dict` returns asdict(KeyBundle) which doesn't include `env`; carry separately.
    raw = json.loads(_decrypt_raw(vault_key))
    raw.update(bundle.to_dict())
    raw.setdefault("env", {})[args.name] = token
    _encrypt_raw(vault_key, json.dumps(raw).encode("utf-8"))
    print(f"Stored {args.name} in the encrypted vault.")


def _decrypt_raw(vault_key: bytes) -> bytes:
    blob = VAULT_FILE.read_bytes()
    nonce, ct = blob[:12], blob[12:]
    return AESGCM(vault_key).decrypt(nonce, ct, associated_data=b"sovereign-vault-v1")


def _encrypt_raw(vault_key: bytes, plaintext: bytes) -> None:
    nonce = secrets.token_bytes(12)
    ct = AESGCM(vault_key).encrypt(
        nonce,
        plaintext,
        associated_data=b"sovereign-vault-v1",
    )
    VAULT_FILE.write_bytes(nonce + ct)


if __name__ == "__main__":
    main()
