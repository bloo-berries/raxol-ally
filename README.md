# Ally

A screen-reader-first AI terminal that makes images and web pages accessible — reachable by SSH, speaking every token through a self-hosted [Otari](https://github.com/mozilla-ai/otari) gateway, using only open-weight vision models.

Built for the [MozFest Developers Wilding](https://otari.ai/devs-wilding) hackathon.

## Three Pillars

**Describe** — Point it at an image (path or URL) and get WCAG-style alt text, a long description, and decorative-image detection. Powered by open VLMs behind a self-hosted Otari gateway with failover routing.

**Audit** — Point it at a URL. Ally finds images missing alt text, generates candidates, and produces an accessible linear summary of the page using Otari's web search/fetch tooling.

**Speak** — The interface itself is the accessibility statement: keyboard-only, a linear screen-reader mode (no box-drawing noise), optional TTS, and one codebase rendering to terminal, browser, SSH, and an agent/MCP surface.

## Architecture

```
ssh / terminal / (browser) ──► Ally (raxol TEA app)
                                   │ per-tenant otk_ virtual key
                                   ▼
                        Self-hosted Otari (docker compose,
                        --profile web-search --profile guardrails --profile code-exec)
                                   │ routing policy: failover
                           ┌───────┴────────┐
                     open VLM #1       open VLM #2 (different provider)
```

## Tech Stack

- **[Raxol](https://github.com/DROOdotFOO/raxol)** — Elixir TUI framework with TEA architecture, multi-surface rendering (terminal, SSH, LiveView, MCP)
- **[Otari](https://github.com/mozilla-ai/otari)** — Self-hosted AI gateway with routing, budgets, guardrails, web search, and code execution
- **Vision prompts** adapted from [AltText Guardian](https://github.com/bloo-berries/AltText-Guardian)

## Otari Features Used

| Feature | Implementation |
|---------|---------------|
| Open-weight models | Two open VLMs compared head-to-head on alt-text quality |
| Model routing / failover | Primary→fallback policy, demonstrated live |
| Virtual keys + scopes | One key minted per SSH tenant |
| Per-user budgets | Per-tenant spend caps enforced before dispatch |
| Usage / cost observability | Per-call cost shown in the TUI; dashboard tour in demo |
| Web search / fetch | URL audit pillar |
| Code execution | WCAG contrast-ratio and image-metadata extraction |
| Guardrails | Output filter on generated descriptions |

## Quick Start

### Requirements

- Elixir 1.17+ / OTP 27+
- A running self-hosted Otari instance (see below)

### Run the TUI

```bash
git clone https://github.com/bloo-berries/raxol-ally.git
cd raxol-ally
mix setup
mix run run.exs
```

### Self-Hosted Otari

In a separate clone of the [Otari fork](https://github.com/bloo-berries/otari):

```bash
cp config.example.yml config.yml
# Edit config.yml: set provider credentials for your open VLMs

docker compose \
  --profile web-search \
  --profile guardrails \
  --profile code-exec \
  up -d
```

### Environment Variables

```bash
cp .env.example .env
# Edit .env with your Otari virtual key and model names
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `OTARI_BASE_URL` | `http://localhost:8000/api/v1` | Otari gateway URL |
| `OTARI_API_KEY` | — | Virtual key for the gateway |
| `ALLY_SSH_PORT` | `2222` | SSH listen port |
| `ALLY_DEFAULT_MODEL` | `llava-v1.6-mistral-7b` | Primary open VLM |
| `ALLY_FALLBACK_MODEL` | `llava-v1.5-7b` | Fallback open VLM |

## Project Structure

```
lib/
├── ally.ex                     # Root module
├── ally/
│   ├── application.ex          # OTP supervision tree
│   ├── app.ex                  # Raxol TEA application (TUI)
│   ├── otari/
│   │   └── client.ex           # Otari OpenAI-compatible API client
│   ├── ssh/
│   │   └── server.ex           # Multi-tenant SSH server
│   └── vision/
│       ├── pipeline.ex         # Describe pipeline (image → alt text)
│       └── prompts.ex          # WCAG-style vision prompts
```

## Team

- [bloo-berries](https://github.com/bloo-berries) — Vision pipeline, VLM prompts, WCAG quality, screen-reader QA
- [DROO](https://github.com/DROOdotFOO) — Raxol scaffold, Otari integration, SSH multi-tenant, deployment

## License

MIT
