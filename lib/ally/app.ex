defmodule Ally.App do
  @moduledoc """
  The Ally TUI application — a screen-reader-first AI terminal.
  Built on the Raxol TEA architecture.
  """
  use Raxol.Core.Runtime.Application

  alias Ally.Otari.Client

  @impl true
  def init(_context) do
    %{
      screen: :home,
      input: "",
      result: nil,
      loading: false,
      error: nil,
      gateway_status: :unknown
    }
  end

  @impl true
  def update(msg, model) do
    case msg do
      # Quit
      %Event{type: :key, data: %{key: :char, char: "q"}} when model.screen == :home ->
        {model, [Directive.stop()]}

      # Navigate: describe mode
      %Event{type: :key, data: %{key: :char, char: "d"}} when model.screen == :home ->
        {%{model | screen: :describe, input: "", result: nil, error: nil}, []}

      # Navigate: audit mode
      %Event{type: :key, data: %{key: :char, char: "a"}} when model.screen == :home ->
        {%{model | screen: :audit, input: "", result: nil, error: nil}, []}

      # Back to home
      %Event{type: :key, data: %{key: :escape}} ->
        {%{model | screen: :home, error: nil}, []}

      # Check gateway health
      %Event{type: :key, data: %{key: :char, char: "h"}} when model.screen == :home ->
        cmd = Directive.spawn_task(fn -> {:health, Client.health()} end)
        {%{model | loading: true}, [cmd]}

      # Type input
      %Event{type: :key, data: %{key: :char, char: c}} when model.screen in [:describe, :audit] ->
        {%{model | input: model.input <> c}, []}

      # Backspace
      %Event{type: :key, data: %{key: :backspace}} when model.screen in [:describe, :audit] ->
        {%{model | input: String.slice(model.input, 0..-2//1)}, []}

      # Submit describe
      %Event{type: :key, data: %{key: :enter}} when model.screen == :describe and model.input != "" ->
        input = model.input
        cmd = Directive.spawn_task(fn ->
          {:describe_result, Ally.Vision.Pipeline.alt_text(input)}
        end)
        {%{model | loading: true}, [cmd]}

      # Task results
      {:command_result, {:health, :ok}} ->
        {%{model | gateway_status: :connected, loading: false}, []}

      {:command_result, {:health, {:error, reason}}} ->
        {%{model | gateway_status: :error, loading: false, error: inspect(reason)}, []}

      {:command_result, {:describe_result, {:ok, text}}} ->
        {%{model | result: text, loading: false}, []}

      {:command_result, {:describe_result, {:error, reason}}} ->
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

  @impl true
  def subscribe(_model), do: []

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
        text("(coming soon)"),
        text(""),
        text("[Esc] Back")
      ]
    end
  end

  defp loading_or_result(%{loading: true}) do
    text("Working...")
  end

  defp loading_or_result(%{error: err}) when is_binary(err) do
    text("Error: #{err}")
  end

  defp loading_or_result(%{result: result}) when is_binary(result) do
    box style: %{border: :single, padding: 1, width: 56} do
      column do
        [
          text("Alt Text:", style: [:bold]),
          text(result)
        ]
      end
    end
  end

  defp loading_or_result(_), do: text("")

  defp gateway_indicator(%{gateway_status: :connected}) do
    text("Gateway: Connected")
  end

  defp gateway_indicator(%{gateway_status: :error}) do
    text("Gateway: Error")
  end

  defp gateway_indicator(_) do
    text("Gateway: Not checked")
  end

  defp status_bar(_model) do
    text("Ally v0.1.0 | Otari gateway | Open-weight VLMs")
  end
end
