defmodule Ally.Otari.Client do
  @moduledoc """
  Client for the self-hosted Otari gateway. Uses the OpenAI-compatible
  chat completions endpoint with vision (image) payloads.

  Supports:
  - Server-side failover: requests name an Otari routing policy as the model
  - Gateway-run tools (`otari_code_execution`), read back from `otari_tool_calls`
  - Guardrails: request-level `guardrails` field, verdicts from `Otari-Guardrails`
  - Usage/cost extraction from responses
  - Otari response header parsing (provider, model, fallback, request ID)
  - Budget exceeded / guardrail violation / rate limit error handling
  """

  require Logger

  alias Ally.Config

  @type completion_result :: %{
          text: String.t() | nil,
          model: String.t() | nil,
          provider: String.t() | nil,
          fallback_used: boolean(),
          attempt_count: integer() | nil,
          request_id: String.t() | nil,
          usage: usage() | nil,
          tool_calls: list(map()),
          guardrails: list(guardrail_verdict())
        }

  @type usage :: %{
          cost_usd: String.t() | nil,
          prompt_tokens: integer() | nil,
          completion_tokens: integer() | nil,
          total_tokens: integer() | nil
        }

  @type guardrail_verdict :: %{
          profile: String.t() | nil,
          mode: String.t() | nil,
          valid: boolean() | nil,
          score: float() | nil,
          status: String.t() | nil,
          reason: String.t() | nil
        }

  @doc """
  Send an image + text prompt to a vision model through Otari.
  Returns a result map with text, model info, and cost.

  Options:
  - `:model`: model or routing policy name (default: `Config.routing_policy/0`,
    so Otari handles primary -> fallback failover server-side)
  - `:api_key`: override the API key (for per-tenant keys)
  - `:base_url`: override the gateway URL
  - `:tools`: list of Otari tool declarations, e.g. `[%{type: "otari_code_execution"}]`
  - `:guardrails`: list of guardrail entries (default: from `Config.guardrail_profile/0`)
  - `:max_tokens`: max response tokens (default: 1024)
  """
  @spec vision_completion(map(), String.t(), keyword()) ::
          {:ok, completion_result()} | {:error, term()}
  def vision_completion(image_data, prompt, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, Config.otari_base_url())
    api_key = Keyword.get(opts, :api_key, Config.otari_api_key())
    model = Keyword.get(opts, :model, Config.routing_policy())
    max_tokens = Keyword.get(opts, :max_tokens, 1024)

    body =
      %{
        model: model,
        messages: [
          %{
            role: "user",
            content: [
              %{type: "text", text: prompt},
              encode_image(image_data)
            ]
          }
        ],
        max_tokens: max_tokens
      }
      |> maybe_add_tools(opts)
      |> maybe_add_guardrails(opts)

    do_request(base_url, api_key, body)
  end

  @doc """
  Send a text-only chat completion through Otari.
  Used for gateway tool calls (code execution) and audit analysis.
  Defaults to `Config.tool_model/0`, which must support tool calling.
  """
  @spec chat_completion(String.t(), keyword()) ::
          {:ok, completion_result()} | {:error, term()}
  def chat_completion(prompt, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, Config.otari_base_url())
    api_key = Keyword.get(opts, :api_key, Config.otari_api_key())
    model = Keyword.get(opts, :model, Config.tool_model())
    max_tokens = Keyword.get(opts, :max_tokens, 1024)

    body =
      %{
        model: model,
        messages: [%{role: "user", content: prompt}],
        max_tokens: max_tokens
      }
      |> maybe_add_tools(opts)
      |> maybe_add_guardrails(opts)

    do_request(base_url, api_key, body)
  end

  @doc "Check gateway health."
  @spec health() :: :ok | {:error, term()}
  def health do
    case Req.get("#{Config.otari_base_url()}/health", receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}} -> {:error, {:unhealthy, s}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "List available models from the gateway."
  @spec list_models(keyword()) :: {:ok, list(map())} | {:error, term()}
  def list_models(opts \\ []) do
    base_url = Keyword.get(opts, :base_url, Config.otari_base_url())
    api_key = Keyword.get(opts, :api_key, Config.otari_api_key())

    case Req.get("#{base_url}/models",
           headers: auth_headers(api_key),
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        {:ok, models}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Create a virtual API key via Otari management API."
  @spec create_virtual_key(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_virtual_key(params, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, Config.otari_base_url())
    master_key = Keyword.get(opts, :master_key, Config.otari_master_key())

    case Req.post("#{base_url}/keys",
           json: params,
           headers: auth_headers(master_key),
           receive_timeout: 10_000
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Create a budget via Otari management API."
  @spec create_budget(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_budget(params, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, Config.otari_base_url())
    master_key = Keyword.get(opts, :master_key, Config.otari_master_key())

    case Req.post("#{base_url}/budgets",
           json: params,
           headers: auth_headers(master_key),
           receive_timeout: 10_000
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Look up per-request cost by Otari request ID."
  @spec get_request_cost(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_request_cost(request_id, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, Config.otari_base_url())
    api_key = Keyword.get(opts, :api_key, Config.otari_api_key())

    case Req.get("#{base_url}/usage/requests/#{request_id}",
           headers: auth_headers(api_key),
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @type budget :: %{
          enforced: boolean(),
          remaining_usd: number() | nil,
          limits: list(budget_limit())
        }

  @type budget_limit :: %{
          scope: String.t() | nil,
          limit_usd: number() | nil,
          used_usd: number() | nil,
          remaining_usd: number() | nil,
          resets_at: String.t() | nil
        }

  @doc """
  What the calling API key may still spend, from `GET /api/v1/key/budget`.
  Readable with the key itself (no master key). Otari enforces the cap
  server-side; this is for showing the user where they stand.
  """
  @spec key_budget(keyword()) :: {:ok, budget()} | {:error, term()}
  def key_budget(opts \\ []) do
    base_url = Keyword.get(opts, :base_url, Config.otari_base_url())
    api_key = Keyword.get(opts, :api_key, Config.otari_api_key())

    case Req.get("#{base_url}/key/budget",
           headers: auth_headers(api_key),
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        limits =
          Enum.map(body["limits"] || [], fn l ->
            %{
              scope: l["scope"],
              limit_usd: l["limit_usd"],
              used_usd: l["used_usd"],
              remaining_usd: l["remaining_usd"],
              resets_at: l["resets_at"]
            }
          end)

        {:ok,
         %{
           enforced: body["budgets_enforced"] == true,
           remaining_usd: body["remaining_usd"],
           limits: limits
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private ---

  defp do_request(base_url, api_key, body) do
    case Req.post("#{base_url}/chat/completions",
           json: body,
           headers: auth_headers(api_key),
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: resp_body, headers: resp_headers}} ->
        parse_success(resp_body, resp_headers)

      {:ok, %{status: 403, body: body, headers: headers}} ->
        handle_forbidden(body, headers)

      {:ok, %{status: 429, headers: headers} = resp} ->
        retry_after = get_header(headers, "retry-after")
        Logger.warning("Rate limited, retry after: #{retry_after}s")
        {:error, {:rate_limited, retry_after, resp.body}}

      {:ok, %{status: 424, body: body}} ->
        Logger.error("Provider credential rejected: #{inspect(body)}")
        {:error, {:provider_credential_rejected, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_success(body, headers) do
    text =
      case body do
        %{"choices" => [%{"message" => %{"content" => t}} | _]} -> t
        _ -> nil
      end

    usage =
      case body do
        %{"usage" => u} ->
          %{
            cost_usd: u["cost_usd"],
            prompt_tokens: u["prompt_tokens"],
            completion_tokens: u["completion_tokens"],
            total_tokens: u["total_tokens"]
          }

        _ ->
          nil
      end

    request_id = get_header(headers, "otari-request-id")
    provider = get_header(headers, "otari-provider")
    model = get_header(headers, "otari-model")
    fallback = get_header(headers, "otari-fallback") == "true"
    attempts = parse_int(get_header(headers, "otari-attempt-count"))
    guardrails = parse_guardrails(get_header(headers, "otari-guardrails"))
    tool_calls = Map.get(body, "otari_tool_calls") || []

    Logger.info(
      "Otari request #{request_id}: model=#{model} provider=#{provider} " <>
        "fallback=#{fallback} attempts=#{attempts} tools=#{length(tool_calls)} " <>
        "guardrails=#{inspect(guardrails)} cost=#{usage[:cost_usd]}"
    )

    {:ok,
     %{
       text: text,
       model: model,
       provider: provider,
       fallback_used: fallback,
       attempt_count: attempts,
       request_id: request_id,
       usage: usage,
       tool_calls: tool_calls,
       guardrails: guardrails
     }}
  end

  defp handle_forbidden(body, headers) do
    error_code = get_header(headers, "otari-error-code")
    message = get_in(body, ["error", "message"]) || body["detail"]

    case error_code do
      "guardrail_violation" ->
        Logger.warning("Guardrail blocked request: #{inspect(message)}")
        {:error, {:guardrail_violation, %{message: message || "Blocked by guardrail"}}}

      _ ->
        retry_after = get_header(headers, "retry-after")
        budget_scope = get_header(headers, "otari-budget-scope")
        Logger.warning("Budget exceeded: scope=#{budget_scope} retry_after=#{retry_after}")

        {:error,
         {:budget_exceeded,
          %{
            error_code: error_code,
            budget_scope: budget_scope,
            retry_after: retry_after,
            message: message || "Budget exceeded"
          }}}
    end
  end

  defp parse_guardrails(nil), do: []

  defp parse_guardrails(header) do
    case Jason.decode(header) do
      {:ok, entries} when is_list(entries) ->
        Enum.map(entries, fn e ->
          %{
            profile: e["profile"],
            mode: e["mode"],
            valid: e["valid"],
            score: e["score"],
            status: e["status"],
            reason: e["reason"]
          }
        end)

      _ ->
        Logger.warning("Unparseable Otari-Guardrails header: #{inspect(header)}")
        []
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp auth_headers(api_key) do
    [{"authorization", "Bearer #{api_key}"}]
  end

  defp get_header(headers, name) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) -> if String.downcase(k) == name, do: List.wrap(v) |> List.first()
      _ -> nil
    end)
  end

  defp encode_image(%{data: data, mime: mime}) do
    %{
      type: "image_url",
      image_url: %{
        url: "data:#{mime};base64,#{Base.encode64(data)}"
      }
    }
  end

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      tools -> Map.put(body, :tools, tools)
    end
  end

  defp maybe_add_guardrails(body, opts) do
    case Keyword.get(opts, :guardrails, default_guardrails()) do
      [] -> body
      guardrails -> Map.put(body, :guardrails, guardrails)
    end
  end

  defp default_guardrails do
    case Config.guardrail_profile() do
      nil -> []
      "" -> []
      profile -> [%{profile: profile, mode: Config.guardrail_mode()}]
    end
  end
end
