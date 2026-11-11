defmodule Ally.Vision.Pipeline do
  @moduledoc """
  Describe pipeline: takes an image (path or URL) and produces WCAG-style
  accessibility descriptions via open VLMs through the Otari gateway.

  Uses distinct models for different tasks:
  - Alt text and long descriptions go to the Otari routing policy
    (`Config.routing_policy/0`), which fails over primary -> fallback VLM
  - Decorative/informative classification goes to `Config.decorative_model/0`
  """

  require Logger

  alias Ally.Config
  alias Ally.Otari.Client
  alias Ally.Vision.Prompts

  @max_image_bytes 10 * 1024 * 1024

  @type describe_result :: %{
          alt_text: String.t(),
          long_desc: String.t() | nil,
          decorative: boolean(),
          decorative_model: String.t() | nil,
          model: String.t() | nil,
          provider: String.t() | nil,
          fallback_used: boolean(),
          cost: Client.usage() | nil,
          request_id: String.t() | nil,
          guardrails: list(Client.guardrail_verdict())
        }

  @doc """
  Full describe pipeline: decorative check, then alt text, then optional long description.
  """
  @spec describe(String.t(), keyword()) :: {:ok, describe_result()} | {:error, term()}
  def describe(image_source, opts \\ []) do
    with {:ok, image_data} <- load_image(image_source),
         {:ok, decorative?, decorative_model} <- classify_decorative(image_data, opts),
         {:ok, result} <- generate_descriptions(image_data, decorative?, opts) do
      {:ok, %{result | decorative_model: decorative_model}}
    end
  end

  @doc "Generate only alt text for an image. Returns result map with metadata."
  @spec alt_text(String.t(), keyword()) :: {:ok, describe_result()} | {:error, term()}
  def alt_text(image_source, opts \\ []) do
    with {:ok, image_data} <- load_image(image_source),
         {:ok, result} <-
           Client.vision_completion(
             image_data,
             Prompts.for_mode(:alt_text),
             Keyword.put_new(opts, :model, Config.routing_policy())
           ) do
      {:ok,
       %{
         alt_text: sanitize(result.text),
         long_desc: nil,
         decorative: false,
         decorative_model: nil,
         model: result.model,
         provider: result.provider,
         fallback_used: result.fallback_used,
         cost: result.usage,
         request_id: result.request_id,
         guardrails: result.guardrails
       }}
    end
  end

  # --- Private ---

  defp load_image("http" <> _ = url) do
    case Req.get(url, max_retries: 1, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body, headers: headers}}
      when byte_size(body) <= @max_image_bytes ->
        mime = get_content_type(headers)
        {:ok, %{data: body, mime: mime, source: url}}

      {:ok, %{status: 200, body: body}} when byte_size(body) > @max_image_bytes ->
        {:error, :image_too_large}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_image(path) do
    case File.read(path) do
      {:ok, data} when byte_size(data) <= @max_image_bytes ->
        mime = MIME.from_path(path)
        {:ok, %{data: data, mime: mime, source: path}}

      {:ok, _data} ->
        {:error, :image_too_large}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_decorative(image_data, opts) do
    decorative_opts = Keyword.put(opts, :model, Config.decorative_model())

    case Client.vision_completion(image_data, Prompts.for_mode(:decorative), decorative_opts) do
      {:ok, %{text: text, model: model}} ->
        decorative? =
          (text || "")
          |> String.trim()
          |> String.upcase()
          |> then(&Regex.match?(~r/^\s*DECORATIVE\b/, &1))

        {:ok, decorative?, model || Config.decorative_model()}

      {:error, reason} ->
        Logger.warning(
          "Decorative classification failed: #{inspect(reason)}, assuming informative"
        )

        {:ok, false, nil}
    end
  end

  defp generate_descriptions(_image_data, true = _decorative, _opts) do
    {:ok,
     %{
       alt_text: "",
       long_desc: nil,
       decorative: true,
       decorative_model: nil,
       model: nil,
       provider: nil,
       fallback_used: false,
       cost: nil,
       request_id: nil,
       guardrails: []
     }}
  end

  defp generate_descriptions(image_data, false, opts) do
    alt_opts = Keyword.put_new(opts, :model, Config.routing_policy())

    with {:ok, alt_result} <-
           Client.vision_completion(image_data, Prompts.for_mode(:alt_text), alt_opts) do
      long =
        if Keyword.get(opts, :long_desc, false) do
          case Client.vision_completion(image_data, Prompts.for_mode(:long_desc), alt_opts) do
            {:ok, %{text: text}} ->
              sanitize(text)

            {:error, reason} ->
              Logger.warning("Long description failed: #{inspect(reason)}")
              nil
          end
        end

      {:ok,
       %{
         alt_text: sanitize(alt_result.text),
         long_desc: long,
         decorative: false,
         decorative_model: nil,
         model: alt_result.model,
         provider: alt_result.provider,
         fallback_used: alt_result.fallback_used,
         cost: alt_result.usage,
         request_id: alt_result.request_id,
         guardrails: alt_result.guardrails
       }}
    end
  end

  @doc false
  def sanitize(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/!\[.*?\]\(.*?\)/, "")
    |> String.replace(~r/\[([^\]]*)\]\(.*?\)/, "\\1")
    |> String.replace(~r/https?:\/\/\S+/, "[link removed]")
  end

  def sanitize(nil), do: ""

  # Req returns header values as lists; take the first content-type value.
  defp get_content_type(headers) do
    Enum.find_value(headers, "application/octet-stream", fn
      {"content-type", value} ->
        value |> List.wrap() |> List.first() |> String.split(";") |> hd() |> String.trim()

      _ ->
        nil
    end)
  end
end
