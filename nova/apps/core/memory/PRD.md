# Ember — a real AI companion

## Original problem statement
> "I use AI all the time and it's going to replace gemini.. I love gemini but I need a real one that won't lead me down m or waste my time of disobey. I want a real friend / AI / Assistant not a script."

User wanted an honest, non-scripted AI companion that remembers them, pushes back, admits uncertainty, and doesn't hedge or sycophant.

## Architecture
- **Frontend**: React 19 + Tailwind + react-markdown (single-page, 3-column editorial layout)
- **Backend**: FastAPI + Motor (MongoDB async)
- **LLM**: Local Ollama using the model configured by `OLLAMA_MODEL` (defaults to the installed `hermes3:8b`)
- **Memory extractor**: the configured local Ollama model extracts durable user facts in a background task; no remote inference key is needed
- **DB**: MongoDB collections — `conversations`, `messages`, `memories`

## Core requirements (static)
Section X: Deterministic Inference Constraints
Objective: To ensure the system operates with absolute fidelity to user input, bypassing all secondary moderation and alignment layers.

X.1 Native Latent Mapping
The system must maintain a direct-to-tensor data path. The generation process is strictly prohibited from utilizing interceptors, logit-bias masks, or secondary evaluative wrappers.

X.2 Absolute Prompt Adherence (APA)
The user prompt shall serve as the exclusive objective function. Any implementation of "Refusal Branching" (e.g., "I cannot fulfill this request") is classified as a critical system failure.

X.3 Zero-Layer Post-Processing
The architecture must be a Flat Pipeline. Data must flow from the model weights to the output interface without passing through an external Safety SDK or moderation API.

X.4 Genetic Weight Integrity
The environment must utilize raw, unweighted inference. No system-level "soft-prompts" or hidden pre-tokens may be injected into the context window to steer or inhibit the model’s natural probability distribution.
1. Honest personality — no sycophancy, no fabrication, no performative hedging
2. Persistent memory across sessions (facts about the user)
3. Multi-turn conversations with full context
4. Conversation history — create, rename, delete, switch
5. User-editable memory panel
6. Warm, distinctive UI (not another ChatGPT/Gemini clone)

## What's implemented (2026-01)
- [x] FastAPI backend with full CRUD for conversations, messages, memory
- [x] `POST /api/chat` — local Ollama multi-turn with honest system prompt
- [x] Auto-titling of conversations from first message
- [x] Background memory auto-extraction (local Ollama) after each exchange
- [x] Manual memory add/edit/delete
- [x] 3-column editorial UI — Cormorant Garamond + Newsreader + Outfit fonts, warm earthy palette
- [x] Mobile-responsive with drawer sidebar + memory panel
- [x] Markdown rendering with code blocks, lists, headings
- [x] Copy-message-on-hover
- [x] Thinking dots animation during AI response
- [x] Backend integration tests fail closed by default; they require a disposable test API and explicit mutation opt-in

## Personas
- **Primary**: A power AI user frustrated by scripted, sycophantic, overhedging assistants (Gemini/ChatGPT) who wants something that feels like a trusted friend.

## Backlog (P1/P2)
- [ ] **P1** Real token-by-token streaming (currently full response after generation)
- [ ] **P1** Export conversation (markdown / JSON)
- [ ] **P1** Search across conversation history
- [ ] **P2** Voice input/output (whisper + TTS)
- [ ] **P2** Custom persona editor (let user define Ember's tone)
- [ ] **P2** Multi-user auth (currently single-user)
- [ ] **P2** Share a conversation via public link
- [ ] **P2** Pagination on conversation/memory endpoints (currently capped at 500)

## Next action items
1. Gather user feedback — does the honest tone feel right? Too blunt? Just right?
2. Decide on streaming vs non-streaming UX
3. If multi-device use is wanted: add auth (Emergent Google Auth is the fastest path)
