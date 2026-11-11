defmodule Ally.App do
  @moduledoc """
  The Ally TUI application: a screen-reader-first AI terminal.
  Built on the Raxol TEA architecture.

  Screens: home, describe, audit, contrast
  """
  use Raxol.Core.Runtime.Application

  alias Ally.Otari.Client
  alias Ally.Tools.ContrastChecker

  @impl true
  def init(context) do
    tenant = Map.get(context || %{}, :tenant, %{})

    model = %{
      screen: :home,
      input: "",
      result: nil,
      audit_result: nil,
      loading: false,
      error: nil,
      gateway_status: :unknown,
      tenant: tenant,
      budget: nil,
      budget_error: nil,
      budget_requested: false,
      last_model: nil,
      last_decorative_model: nil,
      last_provider: nil,
      last_cost: nil,
      last_fallback: false,
      last_request_id: nil,
      last_guardrails: []
    }

    model
  end

  @impl true
  def update(msg, model) do
    {model, cmds} = do_update(msg, model)
    {model, cmds ++ budget_refresh(msg, model)}
  end

  # Re-read the key's budget after every gateway call so the status bar
  # reflects what the last request cost against the cap.
  defp budget_refresh({:command_result, {kind, _}}, model)
       when kind in [:describe_result, :audit_result, :contrast_result],
       do: [budget_cmd(model)]

  defp budget_refresh(_msg, _model), do: []

  # Raxol drops commands returned from init/1 (Lifecycle only runs its own
  # :initial_commands option), so the first budget probe is issued from the
  # first :repaint tick instead; see subscribe/1.
  defp first_tick(%{budget_requested: false} = model) do
    {%{model | budget_requested: true}, [budget_cmd(model)]}
  end

  defp first_tick(model), do: {model, []}

  defp budget_cmd(model) do
    opts = tenant_opts(model)
    Directive.spawn_task(fn -> {:budget, Client.key_budget(opts)} end)
  end

  defp do_update(msg, model) do
    case msg do
      :repaint ->
        first_tick(model)

      # --- Navigation ---
      %Event{type: :key, data: %{key: :char, char: "q"}} when model.screen == :home ->
        {model, [Directive.stop()]}

      %Event{type: :key, data: %{key: :char, char: "d"}} when model.screen == :home ->
        {%{model | screen: :describe, input: "", result: nil, error: nil}, []}

      %Event{type: :key, data: %{key: :char, char: "a"}} when model.screen == :home ->
        {%{model | screen: :audit, input: "", audit_result: nil, error: nil}, []}

      %Event{type: :key, data: %{key: :char, char: "c"}} when model.screen == :home ->
        {%{model | screen: :contrast, input: "", result: nil, error: nil}, []}

      %Event{type: :key, data: %{key: :escape}} ->
        {%{model | screen: :home, error: nil}, []}

      # --- Gateway health ---
      %Event{type: :key, data: %{key: :char, char: "h"}} when model.screen == :home ->
        cmd = Directive.spawn_task(fn -> {:health, Client.health()} end)
        {%{model | loading: true}, [cmd, budget_cmd(model)]}

      # --- Text input ---
      %Event{type: :key, data: %{key: :char, char: c}}
      when model.screen in [:describe, :audit, :contrast] ->
        {%{model | input: model.input <> c}, []}

      %Event{type: :key, data: %{key: :backspace}}
      when model.screen in [:describe, :audit, :contrast] ->
        {%{model | input: String.slice(model.input, 0..-2//1)}, []}

      # --- Submit describe ---
      %Event{type: :key, data: %{key: :enter}}
      when model.screen == :describe and model.input != "" ->
        input = model.input
        tenant_opts = tenant_opts(model)

        cmd =
          Directive.spawn_task(fn ->
            {:describe_result, Ally.Vision.Pipeline.describe(input, tenant_opts)}
          end)

        {%{model | loading: true, result: nil, error: nil}, [cmd]}

      # --- Submit audit ---
      %Event{type: :key, data: %{key: :enter}}
      when model.screen == :audit and model.input != "" ->
        url = normalize_url(model.input)
        tenant_opts = tenant_opts(model)

        cmd =
          Directive.spawn_task(fn ->
            {:audit_result, Ally.Audit.Scanner.audit(url, tenant_opts)}
          end)

        {%{model | loading: true, audit_result: nil, error: nil}, [cmd]}

      # --- Submit contrast check ---
      %Event{type: :key, data: %{key: :enter}}
      when model.screen == :contrast and model.input != "" ->
        input = model.input
        tenant_opts = tenant_opts(model)

        cmd =
          Directive.spawn_task(fn ->
            case parse_colors(input) do
              {:ok, fg, bg} ->
                {:contrast_result, Ally.Tools.ContrastChecker.check_contrast(fg, bg, tenant_opts)}

              :error ->
                {:contrast_result,
                 {:error, "Enter two hex colors separated by space, e.g. #333333 #FFFFFF"}}
            end
          end)

        {%{model | loading: true, result: nil, error: nil}, [cmd]}

      # --- Task results ---
      {:command_result, {:health, :ok}} ->
        {%{model | gateway_status: :connected, loading: false}, []}

      {:command_result, {:health, {:error, reason}}} ->
        {%{model | gateway_status: :error, loading: false, error: inspect(reason)}, []}

      {:command_result, {:describe_result, {:ok, %{decorative: true} = result}}} ->
        {%{
           model
           | result: "Decorative image. Use empty alt text (alt=\"\") so screen readers skip it.",
             loading: false,
             last_model: nil,
             last_decorative_model: result.decorative_model,
             last_provider: nil,
             last_cost: nil,
             last_fallback: false,
             last_request_id: nil,
             last_guardrails: []
         }, []}

      {:command_result, {:describe_result, {:ok, result}}} ->
        {%{
           model
           | result: result.alt_text,
             loading: false,
             last_model: result.model,
             last_decorative_model: result.decorative_model,
             last_provider: result.provider,
             last_cost: format_cost(result.cost),
             last_fallback: result.fallback_used,
             last_request_id: result.request_id,
             last_guardrails: result.guardrails
         }, []}

      {:command_result, {:budget, {:ok, budget}}} ->
        {%{model | budget: budget, budget_error: nil}, []}

      {:command_result, {:budget, {:error, reason}}} ->
        {%{model | budget: nil, budget_error: inspect(reason)}, []}

      {:command_result, {_screen, {:error, {:budget_exceeded, info}}}} ->
        {%{model | error: budget_exceeded_message(info), loading: false}, []}

      {:command_result, {_screen, {:error, {:guardrail_violation, info}}}} ->
        {%{model | error: "Blocked by guardrail: #{info.message}", loading: false}, []}

      {:command_result, {:describe_result, {:error, reason}}} ->
        {%{model | error: inspect(reason), loading: false}, []}

      {:command_result, {:audit_result, {:ok, result}}} ->
        ps = result.page_summary

        {%{
           model
           | audit_result: result,
             loading: false,
             last_model: ps.model,
             last_decorative_model: nil,
             last_provider: ps.provider,
             last_cost: format_cost(ps.usage),
             last_fallback: false,
             last_request_id: ps.request_id,
             last_guardrails: ps.guardrails
         }, []}

      {:command_result, {:audit_result, {:error, reason}}} ->
        {%{model | error: inspect(reason), loading: false}, []}

      {:command_result, {:contrast_result, {:ok, result}}} ->
        {%{
           model
           | result: ContrastChecker.format(result),
             loading: false,
             last_model: result.model,
             last_decorative_model: nil,
             last_provider: result.provider,
             last_cost: format_cost(result.usage),
             last_fallback: false,
             last_guardrails: result.guardrails
         }, []}

      {:command_result, {:contrast_result, {:error, reason}}} ->
        {%{model | error: inspect(reason), loading: false}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        header_view(model),
        main_view(model),
        status_bar(model)
      ]
    end
  end

  # Raxol repaints on events, not on async command results. While a gateway
  # call is in flight (or the initial budget probe has not answered), a tick
  # subscription delivers a message through the event path so the result
  # paints as soon as it lands instead of waiting for the next keypress.
  @impl true
  def subscribe(model) do
    if model.loading or (model.budget == nil and model.budget_error == nil) do
      [Raxol.Core.Runtime.Subscription.interval(250, :repaint)]
    else
      []
    end
  end

  # --- View helpers ---

  defp header_view(_model) do
    box style: %{border: :rounded, padding: 1, width: 60} do
      column do
        [
          text("Ally - Accessible AI Terminal", style: [:bold]),
          text("Screen-reader-first image and web accessibility")
        ]
      end
    end
  end

  defp main_view(%{screen: :home} = model) do
    column style: %{gap: 1} do
      [
        text(""),
        text("[d] Describe - Generate alt text for an image"),
        text("[a] Audit   - Check a URL for missing alt text"),
        text("[c] Contrast - Check WCAG color contrast ratio"),
        text("[h] Health  - Check Otari gateway status"),
        text("[q] Quit"),
        text(""),
        gateway_indicator(model)
      ]
    end
  end

  defp main_view(%{screen: :describe} = model) do
    column style: %{gap: 1} do
      [
        text("Describe: Enter image path or URL", style: [:bold]),
        text(""),
        text("> #{model.input}_"),
        text(""),
        loading_or_result(model),
        text(""),
        model_info(model),
        text("[Enter] Submit  [Esc] Back")
      ]
    end
  end

  defp main_view(%{screen: :audit} = model) do
    column style: %{gap: 1} do
      [
        text("Audit: Enter URL to check for missing alt text", style: [:bold]),
        text(""),
        text("> #{model.input}_"),
        text(""),
        audit_view(model),
        text(""),
        model_info(model),
        text(""),
        text("[Enter] Submit  [Esc] Back")
      ]
    end
  end

  defp main_view(%{screen: :contrast} = model) do
    column style: %{gap: 1} do
      [
        text("Contrast: Enter two hex colors (fg bg)", style: [:bold]),
        text("Example: #333333 #FFFFFF"),
        text(""),
        text("> #{model.input}_"),
        text(""),
        loading_or_result(model),
        text(""),
        model_info(model),
        text(""),
        text("[Enter] Submit  [Esc] Back")
      ]
    end
  end

  defp loading_or_result(%{loading: true}), do: text("Working...")

  defp loading_or_result(%{error: err}) when is_binary(err), do: text("Error: #{err}")

  defp loading_or_result(%{result: result}) when is_binary(result) do
    box style: %{border: :single, padding: 1, width: 56} do
      column do
        [
          text("Result:", style: [:bold]),
          text(result)
        ]
      end
    end
  end

  defp loading_or_result(_), do: text("")

  defp audit_view(%{loading: true}), do: text("Scanning page...")

  defp audit_view(%{error: err}) when is_binary(err), do: text("Error: #{err}")

  defp audit_view(%{audit_result: %{} = r}) do
    findings =
      r.images
      |> Enum.take(8)
      |> Enum.map(fn img ->
        status = Atom.to_string(img.status)
        line = "[#{status}] #{truncate(img.src, 40)}"

        if img.generated_alt do
          line <> " -> #{truncate(img.generated_alt, 30)}"
        else
          line
        end
      end)

    column do
      [
        text(r.summary, style: [:bold]),
        text("")
      ] ++
        Enum.map(findings, &text/1) ++
        [text("")] ++
        page_summary_view(r.page_summary)
    end
  end

  defp audit_view(_), do: text("")

  defp page_summary_view(%{text: nil, error: error}) do
    [text("Page summary unavailable: #{error || "no text returned"}")]
  end

  defp page_summary_view(%{text: summary, fetches: fetches}) do
    fetched =
      case fetches do
        [] ->
          "Page summary (model did not call Otari web fetch):"

        [%{url: url} | _] ->
          "Page summary (fetched by Otari web fetch: #{truncate(url || "?", 40)}):"
      end

    [text(fetched, style: [:bold])] ++
      (summary |> String.split("\n", trim: true) |> Enum.map(&text/1))
  end

  defp model_info(%{last_model: nil, last_decorative_model: nil}), do: text("")

  defp model_info(model) do
    parts = if model.last_model, do: ["Model: #{model.last_model}"], else: []
    parts = if model.last_provider, do: parts ++ ["via #{model.last_provider}"], else: parts

    parts =
      if model.last_decorative_model,
        do: parts ++ ["decorative check: #{model.last_decorative_model}"],
        else: parts

    parts = if model.last_cost, do: parts ++ ["cost: #{model.last_cost}"], else: parts
    parts = if model.last_fallback, do: parts ++ ["[FALLBACK]"], else: parts
    parts = parts ++ Enum.map(model.last_guardrails, &guardrail_summary/1)

    text(Enum.join(parts, " | "), style: [:dim])
  end

  defp guardrail_summary(%{profile: profile, status: "evaluated", valid: valid}) do
    "guardrail #{profile}: #{if valid, do: "pass", else: "FLAGGED"}"
  end

  defp guardrail_summary(%{profile: profile, status: status}) do
    "guardrail #{profile}: #{status || "unknown"}"
  end

  defp gateway_indicator(%{gateway_status: :connected}), do: text("Gateway: Connected")
  defp gateway_indicator(%{gateway_status: :error}), do: text("Gateway: Error")
  defp gateway_indicator(_), do: text("Gateway: Not checked")

  defp status_bar(model) do
    tenant_info =
      case model.tenant do
        %{tenant_id: id} when is_binary(id) -> " | Tenant: #{id}"
        _ -> ""
      end

    column do
      [
        text("Ally v0.1.0 | Otari gateway | Open-weight VLMs#{tenant_info}"),
        text(budget_line(model))
      ]
    end
  end

  defp budget_line(%{budget: nil, budget_error: nil}), do: "Budget: checking..."

  defp budget_line(%{budget: nil, budget_error: err}),
    do: "Budget: unknown (#{truncate(err, 50)})"

  defp budget_line(%{budget: %{enforced: false}}), do: "Budget: not enforced on this key"

  defp budget_line(%{budget: %{remaining_usd: nil, limits: []}}),
    do: "Budget: no cap on this key"

  defp budget_line(%{budget: %{remaining_usd: remaining, limits: limits}}) do
    tightest =
      Enum.find(limits, fn l -> l.limit_usd != nil end)

    base =
      case remaining do
        nil -> "Budget: capped (tokens or requests)"
        r -> "Budget: $#{format_usd(r)} remaining"
      end

    case tightest do
      %{limit_usd: limit, scope: scope, resets_at: resets} ->
        reset = if resets, do: ", resets #{String.slice(resets, 0, 10)}", else: ""
        base <> " of $#{format_usd(limit)} (#{scope})" <> reset

      nil ->
        base
    end
  end

  defp budget_exceeded_message(%{message: message, retry_after: retry_after, budget_scope: scope}) do
    scope_part = if scope, do: " (#{scope} budget)", else: ""
    retry_part = if retry_after, do: " Retry after #{retry_after}s.", else: ""
    "Budget exceeded#{scope_part}: #{message}.#{retry_part}"
  end

  defp format_usd(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 4)
  defp format_usd(other), do: to_string(other)

  # --- Helpers ---

  defp tenant_opts(%{tenant: %{api_key: key}}) when is_binary(key) and key != "" do
    [api_key: key]
  end

  defp tenant_opts(_), do: []

  defp format_cost(%{cost_usd: cost}) when is_binary(cost), do: "$#{cost}"
  defp format_cost(_), do: nil

  defp normalize_url(input) do
    if String.starts_with?(input, "http") do
      input
    else
      "https://#{input}"
    end
  end

  defp parse_colors(input) do
    case String.split(String.trim(input)) do
      [fg, bg] when byte_size(fg) >= 4 and byte_size(bg) >= 4 ->
        {:ok, fg, bg}

      _ ->
        :error
    end
  end

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end

  defp truncate(str, _max), do: str
end
