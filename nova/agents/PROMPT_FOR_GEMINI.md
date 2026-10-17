# Retired historical prompt — Google is not an active NOVA backend

This file previously instructed a manual Gemini integration. That provider path has been removed from the active NOVA agent router and `GEMINI_API_KEY` is no longer accepted by the NOVA token setup helper.

NOVA now defaults to local Ollama. If an owner explicitly adds `OPENROUTER_API_KEY`, the router uses model IDs ending in `:free` and excludes Google. Groq/Hugging Face remain optional, owner-supplied free-tier connectors.

The original prompt is preserved outside Git at:
`/home/justin/.local/share/repo-recovery/NOVA-SOVEREIGN-AI/legacy-google-prompt-20261017/PROMPT_FOR_GEMINI.md.before-deprecation`
