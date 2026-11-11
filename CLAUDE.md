# Ally (raxol-ally)

A screen-reader-first AI terminal that makes images and web pages accessible.
Reachable by SSH, speaking every token through a self-hosted Otari gateway,
using only open-weight vision models.

## Architecture

```
ssh / terminal / (browser) ──► Ally (raxol TEA app)
                                   │ per-tenant otk_ virtual key
                                   ▼
                        Self-hosted Otari (docker compose)
                                   │ routing policy: failover
                           ┌───────┴────────┐
                     open VLM #1       open VLM #2
```

## Key Modules

- `Ally.Vision.Pipeline`: Describe pipeline: image → alt text + long desc + decorative check
- `Ally.Vision.Prompts`: WCAG-style prompts adapted from AltText Guardian
- `Ally.Otari.Client`: HTTP client for the Otari OpenAI-compatible gateway
- `Ally.SSH.Server`: Multi-tenant SSH with per-pubkey virtual keys
- `Ally.App`: Raxol TEA application (TUI)

## Dependencies

- [Raxol](https://github.com/DROOdotFOO/raxol): TUI framework (Elixir, TEA architecture)
- [Otari](https://github.com/mozilla-ai/otari): Self-hosted AI gateway (separate repo, Docker)
- Vision prompts adapted from [AltText Guardian](https://github.com/bloo-berries/AltText-Guardian)

## Dev Setup

```bash
# Elixir deps
mix setup

# Self-hosted Otari (in separate clone of bloo-berries/otari)
docker compose --profile web-search --profile guardrails --profile code-exec up -d
```

## Environment Variables

- `OTARI_BASE_URL`: Otari gateway URL (default: http://localhost:8000/api/v1)
- `OTARI_API_KEY`: Virtual key for the gateway
- `ALLY_SSH_PORT`: SSH listen port (default: 2222)
- `ALLY_ROUTING_POLICY`: Otari failover policy name, sent as `model` (default: ally-failover)
- `ALLY_PRIMARY_MODEL`: Primary open VLM (policy's first candidate)
- `ALLY_FALLBACK_MODEL`: Fallback open VLM (different provider)
- `ALLY_DECORATIVE_MODEL`: Second open VLM for decorative classification
- `ALLY_TOOL_MODEL`: Model for code execution (must support tool calling)
- `ALLY_GUARDRAIL_PROFILE` / `ALLY_GUARDRAIL_MODE`: Guardrail attached to every completion

## Hackathon Context

- **Hackathon**: Devs Wilding (otari.ai/devs-wilding), deadline Nov 11
- **Team**: bloo-berries + DROO
- **Three pillars**: Describe (image → alt text), Audit (URL → missing alt text), Speak (accessible interface)
- **Self-hosted Otari** is the deployment model, not the hosted gateway

## Official Rubric (100 points)

### 1. Open-weight models (30 pts)
- 20 pts: Meaningfully uses at least one open-weight model
- 10 pts: Uses two or more open-weight models for different purposes

### 2. Otari features (up to 60 pts, 10 each, capped at 60)

| Feature | Points | Where it appears in Ally |
|---------|--------|--------------------------|
| Model routing and fallbacks | 10 | Primary→fallback VLM policy, demonstrated live (kill primary mid-session) |
|MCP integrations|10|Raxol MCP server: agent drives the app|
| Web search or web fetch | 10 | URL audit pillar: fetch page, find missing alt text |
| Code execution | 10 | WCAG contrast-ratio math, image metadata extraction |
| Budgets and spending limits | 10 | Per-tenant spend caps enforced before dispatch |
| Multiple models serving distinct roles | 10 | VLM #1 for alt text, VLM #2 for decorative classification / long desc |
| Guardrails | 10 | Output filter on generated descriptions (guardrails profile) |
| Per-user budgets | 10 | One Otari virtual key per SSH tenant with individual budget |

Note: 8 features available (80 pts possible) but capped at 60. We can miss 2 and still max out.
A feature only earns points when **actually used in the application**, not simply enabled in the dashboard.

### 3. Project and demonstration (10 pts)
- 5 pts: Application works and demonstrates a real use case
- 5 pts: Video clearly explains how Otari was integrated and demonstrates claimed capabilities

## Conventions

- Elixir 1.17+, OTP 27+
- `mix format` before commit
- Screen-reader-friendly output: no box-drawing characters in screen-reader mode
- All image descriptions must pass through `sanitize/1` before display
