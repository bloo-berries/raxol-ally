# Ally — Development TODO

## Current Rubric Score: ~22/100

| Category | Available | Current | Notes |
|----------|-----------|---------|-------|
| Open-weight models (1 model) | 20 | 20 | LLaVA via Otari works in theory |
| Open-weight models (2+ models) | 10 | 0 | Fallback model configured but never called |
| Otari features (6 of 8 needed) | 60 | 0 | All 8 features are stubs or missing |
| Project and demo | 10 | ~2 | App renders but no SSH, no real pipeline test |
| **Total** | **100** | **~22** | |

---

## Critical Bugs (Fix First)

- [ ] **Client ignores Application config** — `Ally.Otari.Client` reads `System.get_env` directly instead of `Application.get_env(:ally, ...)`. The `config/config.exs` and `config/runtime.exs` values are dead code. Unify to use Application config with env var fallbacks in `runtime.exs`.
- [ ] **`cost: nil` hardcoded** — Otari returns `usage.cost_usd`, `usage.prompt_tokens`, `usage.completion_tokens` in every chat completion response. The client discards the entire `usage` object. Extract and surface it.
- [ ] **Supervisor children commented out** — `Ally.Application` starts an empty supervisor. Both `Otari.Client` and `SSH.Server` are commented out. Nothing Otari-related is supervised.
- [ ] **`mime` not declared in mix.exs** — `MIME.from_path/1` is used in `pipeline.ex` but `:mime` is only a transitive dep of `:req`. Declare it explicitly.
- [ ] **Audit screen Enter key missing** — The `:audit` screen renders an input prompt but `update/2` has no `%Event{key: :enter}` clause for `:audit` state. Pressing Enter does nothing.
- [ ] **Decorative classification fragile** — `String.starts_with?(String.upcase(text), "DECORATIVE")` will miss models that output `"The image is decorative"` or `"DECORATIVE."` with leading whitespace. Trim and use regex.

---

## Tier 1 — High Impact, Low Effort (10 pts each)

### 1. Model Routing and Fallbacks (10 pts)

**Current**: No retry, no failover. A single failed request returns an error.

**What to build**:
- Add retry logic in `Client.vision_completion/3` — on error or non-200, retry with `fallback_model`
- Read the `Otari-Fallback` response header to confirm fallback was used
- Surface `Otari-Provider`, `Otari-Model`, `Otari-Attempt-Count` headers in the result
- **OR** configure a named routing policy in Otari's config and pass it via `Otari-Router` request header — the gateway handles failover server-side, which is cleaner and more demonstrable

**Otari API**:
- `POST /api/v1/routing/policies` — create a failover policy
- `Otari-Router: <policy-name>` header on chat completions
- Response includes `Otari-Fallback: true` when failover fired

**Demo beat**: Kill the primary VLM provider mid-session, show the request rescued by the fallback in the TUI + Otari dashboard.

---

### 2. Multiple Models Serving Distinct Roles (10 pts)

**Current**: All three vision calls (decorative, alt_text, long_desc) use the same `default_model`.

**What to build**:
- Configure two different open VLMs (e.g., LLaVA-v1.6-Mistral for alt text, Qwen2-VL for decorative classification)
- Pass distinct model names per call type in `pipeline.ex`
- Show head-to-head quality comparison in the TUI or demo

**Bonus**: This also secures the remaining 10 pts for "two or more open-weight models for different purposes" (total 30/30 on category 1).

---

### 3. Guardrails (10 pts)

**Current**: `sanitize/1` does DIY text stripping. No Otari guardrails integration.

**What to build**:
- Enable the `guardrails` Docker Compose profile on self-hosted Otari
- Register a guardrail via `POST /api/v1/organizations/me/guardrails` with an appropriate profile (e.g., PIGuard for prompt injection, or a custom definition for alt-text quality)
- Otari applies guardrails automatically on gated requests — no client code change needed beyond enabling
- **Or**: Pass generated descriptions through `POST .../guardrails/{id}/test` as a validation step before displaying to the user
- Show guardrail blocks/monitors in the Otari dashboard during the demo

**Otari API**:
- `POST /api/v1/organizations/me/guardrails` — register guardrail
- `POST /api/v1/organizations/me/guardrails/{id}/test` — test a string
- Profile catalog: `GET /api/v1/tool-settings/guardrails/profiles`

---

## Tier 2 — High Impact, Moderate Effort (10 pts each)

### 4. Web Search / Web Fetch — Audit Pillar (10 pts)

**Current**: Audit screen says "(coming soon)". No HTML parsing, no missing-alt-text detection.

**What to build**:
- New module `Ally.Audit.Scanner`:
  - Use Otari's web fetch: include `otari_web_fetch` in the `tools` array on a chat completion, or use `POST /api/v1/search` directly
  - OR use Req to fetch the page directly, parse HTML with Floki (add dep), find `<img>` tags with missing/empty `alt` attributes
  - For each image missing alt text, run `Pipeline.alt_text/1`
  - Produce a report: total images, missing alt, generated candidates
- Wire the audit screen's Enter key in `app.ex` `update/2`
- Display results in the TUI

**Otari API**:
- `Otari-Web-Fetch: otari` header on chat completions
- Or `POST /api/v1/search` for direct web search
- Or include `otari_web_search` / `otari_web_fetch` in the `tools[]` array

**Dep to add**: `{:floki, "~> 0.36"}` for HTML parsing

---

### 5. Per-User Budgets + Virtual Keys (10+10 pts)

**Current**: `SSH.Server` is 4 lines of comments. No virtual key minting, no per-tenant isolation.

**What to build**:
- Implement `Ally.SSH.Server` using `Raxol.SSH.serve/2`:
  - Map SSH public key fingerprints to tenant IDs (simple ETS table or map)
  - On new connection: call Otari management API to mint a virtual key with a budget cap
  - Pass the per-tenant key into `Ally.App.init/1` via context
  - `Client.vision_completion/3` uses the tenant's key instead of the global one
- Budget enforcement: Otari enforces budgets server-side on virtual keys. Handle `403 budget_exceeded` in the client gracefully (display "Budget exceeded, contact admin").

**Otari API**:
- `POST /api/v1/keys` — create virtual key with `allowed_models`, `metadata`
- `POST /api/v1/budgets` — create a budget with `max_budget` USD ceiling
- Key creation can reference a `budget_id` via scoped budgets
- Service key + `PUT /api/v1/keys/{id}/end-users/{external_id}` with `{budget_id}` for per-SSH-user budgets
- `GET /api/v1/end-users/{id}/budget` — check remaining budget

**This covers two rubric features**: "Budgets and spending limits" (10 pts) + "Per-user budgets" (10 pts).

---

## Tier 3 — High Impact, Heavy Lift (10 pts each)

### 6. Code Execution (10 pts)

**Current**: Entirely absent. CLAUDE.md mentions "WCAG contrast-ratio math" but no code exists.

**What to build**:
- Enable `code-exec` Docker Compose profile on self-hosted Otari
- New module `Ally.Tools.ContrastChecker`:
  - Include `otari_code_execution` in the `tools[]` array on a chat completion
  - Ask the model to write Python that extracts image metadata (EXIF, dimensions, color profile) or computes WCAG contrast ratios between foreground/background colors
  - Parse the code execution result and surface it in the TUI
- Alternative: use `POST /api/v1/mcp/execute` if code-exec is exposed as an MCP tool

**Otari API**:
- Include `{"type": "code_interpreter", "code_interpreter": {}}` in the `tools[]` array
- Or use `Otari-Code-Execution: otari` header
- Response includes code execution results in the tool call response

---

### 7. MCP Integrations (10 pts)

**Current**: Zero MCP code. Not mentioned in any source file.

**What to build** — two angles, pick one or both:

**Option A — Ally as MCP client (use Otari's managed MCP)**:
- Register an MCP server in Otari (e.g., a WCAG reference server, or the accessibility tools MCP)
- Pass `mcp_server_ids` in chat completion requests
- Otari manages the tool loop

**Option B — Ally as MCP server (Raxol has built-in MCP)**:
- Raxol already ships `raxol_mcp` package
- Expose Ally's describe/audit capabilities as MCP tools
- An external agent can drive Ally: "describe this image", "audit this URL"
- Demo: Claude Code or another agent calling Ally via MCP

**Otari API (Option A)**:
- `POST /api/v1/workspaces/{id}/mcp-servers` — register external MCP server
- `GET /api/v1/mcp/servers/{id}/tools` — discover available tools
- `POST /api/v1/mcp/execute` — execute a tool call
- Or pass `mcp_server_ids` in the chat completions body for managed loop

---

## Structural Improvements

### Config Unification
- [ ] Refactor `Client` to read from `Application.get_env(:ally, :key)` instead of `System.get_env`
- [ ] Add a `Ally.Config` module that centralizes all config access with fallback chain: app config → env var → default
- [ ] Move model names into config: `:primary_vlm`, `:fallback_vlm`, `:decorative_vlm`

### Response Metadata Extraction
- [ ] Parse and return `usage` from Otari response: `cost_usd`, `prompt_tokens`, `completion_tokens`
- [ ] Parse and return Otari response headers: `Otari-Provider`, `Otari-Model`, `Otari-Fallback`, `Otari-Request-ID`
- [ ] Surface cost per request in the TUI

### Error Handling
- [ ] Handle `403 budget_exceeded` specifically — show user-friendly message + `Retry-After`
- [ ] Handle `424 provider_credential_rejected` — alert, don't retry
- [ ] Handle `429 rate_limited` / `upstream_rate_limited` — respect `Retry-After`
- [ ] Handle `502 provider_error` — trigger fallback
- [ ] Log `Otari-Request-ID` on every call for debugging

### Test Coverage
- [ ] Mock HTTP layer (Req.Test or Bypass) for `Client` unit tests
- [ ] Test `Pipeline.describe/2` with mocked client
- [ ] Test `Pipeline.sanitize/1` edge cases
- [ ] Test decorative classification parsing
- [ ] Integration test: health check against a running Otari instance

### Accessibility (The Product's Raison d'Etre)
- [ ] Screen-reader output mode: strip all box-drawing characters, emit linear text
- [ ] TTS flag: pipe output through `espeak-ng` or system TTS
- [ ] Keyboard-only navigation confirmation (no mouse-dependent interactions)
- [ ] Announce state changes (loading, result ready, error) for screen readers

---

## Schedule Alignment (Deadline: Nov 11)

| Date | Priority Tasks |
|------|---------------|
| Oct 31 | Fix critical bugs (config, cost extraction, supervisor). Spike: push an image through self-hosted Otari to two VLMs. |
| Nov 1–2 | Tier 1: routing/fallback, multiple models, guardrails. Describe pipeline working e2e. |
| Nov 3–4 | Tier 2: SSH multi-tenant + virtual keys + per-user budgets. Public SSH instance. |
| Nov 5–6 | Tier 2: audit pillar (web fetch). Tier 3: code execution. |
| Nov 7 | Tier 3: MCP (stretch). Hard cut for anything not working. |
| Nov 8–9 | Feature freeze. Screen-reader QA. Writeup. |
| Nov 10 | Demo video. Submit. |
| Nov 11 | Buffer. |

---

## Target Score: 90–100/100

| Category | Target | How |
|----------|--------|-----|
| Open-weight models | 30/30 | Two VLMs for distinct roles (alt text vs decorative) |
| Model routing / fallbacks | 10/10 | Otari routing policy, live failover demo |
| Web search / web fetch | 10/10 | Audit pillar via Otari web fetch |
| Code execution | 10/10 | WCAG contrast-ratio via Otari sandbox |
| Budgets + spending limits | 10/10 | Per-tenant virtual keys with budget caps |
| Per-user budgets | 10/10 | SSH pubkey → Otari virtual key mapping |
| Guardrails | 10/10 | Otari guardrails profile on output |
| Multiple models / distinct roles | _(counted above)_ | |
| MCP integrations | _(stretch, 7th feature)_ | Raxol MCP server or Otari managed MCP |
| Project + demo | 10/10 | Working SSH app + 4-min video |
| **Total** | **100** | 6 of 8 Otari features = 60 cap hit |
