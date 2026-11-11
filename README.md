# Ally

A screen-reader-first (computer vision) AI terminal that makes images and web pages accessible. Reachable by SSH, speaking every token through an [Otari](https://github.com/mozilla-ai/otari) gateway (hosted or self-hosted), using only open-weight vision models.

<video src="https://github.com/bloo-berries/raxol-ally/releases/download/v0.1.0-demo/Raxol-Ally-Otari-Demo.mp4" controls width="100%"></video>

Built for the [MozFest Developers Wilding](https://otari.ai/devs-wilding) hackathon.

<img width="833" height="705" alt="demo-screenshot" src="https://github.com/user-attachments/assets/907c73d0-eb92-43ed-bdf5-569bfa5bdb28" />


## Three Pillars

**Describe**: Point it at an image (path or URL) and get WCAG-style alt text, a long description, and decorative-image detection. Powered by open VLMs (Alibaba Qwen 3.5) behind an Otari gateway.

**Audit**: Point it at a URL. Ally fetches the page, finds all images, checks which have alt text, and generates candidates for those that don't. With web fetch enabled, it also produces an accessible linear summary.

**Speak**: The interface itself is the accessibility statement: keyboard-only, a linear screen-reader mode (no box-drawing noise), and one codebase serving the terminal directly or over SSH.

## Architecture

```
ssh / terminal / (browser) ---> Ally (raxol TEA app)
                                   | per-tenant virtual key
                                   v
                        Otari gateway (hosted or self-hosted)
                                   | open-weight VLM routing
                           +-------+--------+
                     open VLM #1       open VLM #2
              (e.g. Qwen 3.5 397B)  (e.g. Qwen 3.5 35B)
```

## Tech Stack

- **[Raxol](https://github.com/DROOdotFOO/raxol)**: Elixir TUI framework with TEA architecture, multi-surface rendering (terminal, SSH, LiveView, MCP)
- **[Otari](https://github.com/mozilla-ai/otari)**: AI gateway (hosted or self-hosted) with routing, budgets, guardrails, web search, and code execution
- **Vision prompts** adapted from [AltText Guardian](https://github.com/bloo-berries/AltText-Guardian)

## Otari Features Used

Each row names where the feature is exercised in the app, not just enabled on the gateway.

| Feature | Where it is used in Ally |
|---------|--------------------------|
| Open-weight models | Alibaba Qwen 3.5 VLMs for alt text generation and decorative classification (`lib/ally/vision/pipeline.ex`) |
| Multiple models, distinct roles | `ALLY_PRIMARY_MODEL` (Qwen 3.5 397B) writes descriptions; `ALLY_DECORATIVE_MODEL` (Qwen 3.5 35B) classifies decorative vs. informative. The TUI shows both model names per result |
| Model routing / fallback | `Otari-Fallback` and `Otari-Attempt-Count` headers are parsed in `lib/ally/otari/client.ex` and shown as `[FALLBACK]` in the TUI. Self-hosted deployments can define a named failover routing policy |
| Web fetch | Audit screen requests a page summary via `otari_web_fetch`; the fetch Otari ran is read back from `otari_tool_calls` (`lib/ally/audit/scanner.ex`). Requires web fetch enabled on the gateway |
| Code execution | Contrast screen declares `otari_code_execution`; the sandbox runs WCAG luminance math and its stdout/exit code are shown from `otari_tool_calls` (`lib/ally/tools/contrast_checker.ex`) |
| Guardrails | Every completion carries a `guardrails` entry (`ALLY_GUARDRAIL_PROFILE`); the `Otari-Guardrails` verdict is shown next to each result, and `block` mode surfaces the 403 |
| Budgets and spending limits | The status bar reads `GET /api/v1/key/budget` on start and after every call; a `403 budget_exceeded` is shown with its scope and `Retry-After` |
| Usage / cost observability | Per-call cost (`usage.cost_usd`) shown in the TUI |

Audit Feature: 

<img width="695" height="679" alt="audit-feature" src="https://github.com/user-attachments/assets/10820be6-3c55-4e40-9398-8fa3871ad554" />



Implementation notes: MCP tool definitions exist in `lib/ally/mcp/server.ex` (no transport layer yet). Per-SSH-key virtual key minting is implemented in `lib/ally/ssh/server.ex` but the SSH listener currently runs anonymous, so every session uses `OTARI_API_KEY`.

## Quick Start

### Requirements

- Elixir 1.17+ / OTP 27+
- An Otari gateway: either [hosted](https://otari.ai) or [self-hosted](https://github.com/mozilla-ai/otari)

### Run the TUI

```bash
git clone https://github.com/bloo-berries/raxol-ally.git
cd raxol-ally
mix setup
mix run run.exs
```

### Serve it over SSH (localhost)

```bash
ALLY_SSH_ENABLED=true mix run --no-halt
# in another terminal
ssh -p 2222 localhost
```

The listener binds loopback only, accepts any client (anonymous), and caps
connections, idle time and session length. Every connection runs its own
instance of the app.

### Self-Hosted Otari

In a separate clone of [Otari](https://github.com/mozilla-ai/otari), follow the
[self-hosted quickstart](https://docs.otari.ai/self-hosting/self-hosted-quickstart),
then start the profiles Ally uses:

```bash
docker compose \
  --profile guardrails \
  --profile code-exec \
  up -d
```

Ally needs three things configured on the gateway:

1. **Two VLM providers** (hosted providers or `providers:` entries), so the policy below has a real fallback.
2. **A failover routing policy** named `ally-failover` (or whatever `ALLY_ROUTING_POLICY` is set to), in `config.yml`:

   ```yaml
   routing:
     policies:
       ally-failover:
         select:
           - default: nebius:Qwen/Qwen2.5-VL-72B-Instruct
         on_failure:
           - together:meta-llama/Llama-4-Scout-17B-16E-Instruct
   ```

   or via `POST /api/v1/routing/policies` with the master key. Ally sends `model: ally-failover`.
3. **A guardrail profile** served by the guardrails sidecar. List them with
   `GET /api/v1/tool-settings/guardrails/profiles` and put one in `ALLY_GUARDRAIL_PROFILE`.

### Environment Variables

```bash
cp .env.example .env
# Edit .env with your Otari virtual key and model names
```

| Variable | Default | Purpose |
|----------|---------|---------|
| `OTARI_BASE_URL` | `http://localhost:8000/api/v1` | Otari gateway URL. For hosted Otari: `https://api.otari.ai/api/v1` |
| `OTARI_API_KEY` | (none) | Virtual key for the gateway (`tk-...`) |
| `OTARI_MASTER_KEY` | (none) | Master key, used only to mint per-tenant keys |
| `ALLY_SSH_PORT` | `2222` | SSH listen port |
| `ALLY_ROUTING_POLICY` | `ally-failover` | Otari routing policy sent as `model` for alt text |
| `ALLY_PRIMARY_MODEL` | placeholder | Primary open VLM (`provider:model`); the policy's first candidate |
| `ALLY_FALLBACK_MODEL` | placeholder | Fallback open VLM, different provider; the policy's `on_failure` |
| `ALLY_DECORATIVE_MODEL` | primary | Second open VLM for decorative classification |
| `ALLY_TOOL_MODEL` | routing policy | Model for code execution and web fetch; must support tool calling |
| `ALLY_GUARDRAIL_PROFILE` | (none) | Guardrail profile to attach to every completion |
| `ALLY_GUARDRAIL_MODE` | `monitor` | `monitor` or `block` |
| `ALLY_TENANT_BUDGET_USD` | `1.00` | Per-tenant budget cap |

Model names must be in Otari's `provider:model` form; check `GET /api/v1/models` on your gateway.

## Project Structure

```
lib/
+-- ally.ex                     # Root module
+-- ally/
    +-- application.ex          # OTP supervision tree
    +-- app.ex                  # Raxol TEA application (TUI)
    +-- config.ex               # Centralized config access
    +-- audit/
    |   +-- scanner.ex          # URL audit: find images missing alt text
    +-- mcp/
    |   +-- server.ex           # MCP tool definitions (describe, audit, contrast)
    +-- otari/
    |   +-- client.ex           # Otari OpenAI-compatible API client
    +-- ssh/
    |   +-- server.ex           # Multi-tenant registry: pubkey -> virtual key
    +-- tools/
    |   +-- contrast_checker.ex # WCAG contrast via Otari code execution
    +-- vision/
        +-- pipeline.ex         # Describe pipeline (image -> alt text)
        +-- prompts.ex          # WCAG-style vision prompts
```

## Team

- [bloo-berries](https://github.com/bloo-berries): Vision pipeline, VLM prompts, WCAG quality, screen-reader QA
- [DROO](https://github.com/DROOdotFOO): Raxol scaffold, Otari integration, SSH multi-tenant, deployment

## License

MIT
