defmodule Ally.Vision.Pipeline do
  @moduledoc """
  Describe pipeline: takes an image (path or URL) and produces WCAG-style
  accessibility descriptions via open VLMs through the Otari gateway.
  """

  alias Ally.Otari.Client
  alias Ally.Vision.Prompts

  @max_image_bytes 10 * 1024 * 1024

  @type describe_result :: %{
          alt_text: String.t(),
          long_desc: String.t() | nil,
          decorative: boolean(),
          model: String.t(),
          cost: map() | nil
        }

  @doc """
  Full describe pipeline: decorative check → alt text → optional long description.
  """
  @spec describe(String.t(), keyword()) :: {:ok, describe_result()} | {:error, term()}
  def describe(image_source, opts \\ []) do
    with {:ok, image_data} <- load_image(image_source),
         {:ok, decorative_result} <- classify_decorative(image_data, opts),
         {:ok, result} <- generate_descriptions(image_data, decorative_result, opts) do
      {:ok, result}
    end
  end

  @doc "Generate only alt text for an image."
  @spec alt_text(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def alt_text(image_source, opts \\ []) do
    with {:ok, image_data} <- load_image(image_source),
         {:ok, text} <- Client.vision_completion(image_data, Prompts.for_mode(:alt_text), opts) do
      {:ok, sanitize(text)}
    end
  end

  # --- Private ---

  defp load_image("http" <> _ = url) do
    case Req.get(url, max_retries: 1, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body, headers: headers}} when byte_size(body) <= @max_image_bytes ->
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
    case Client.vision_completion(image_data, Prompts.for_mode(:decorative), opts) do
      {:ok, text} ->
        decorative = String.starts_with?(String.upcase(text), "DECORATIVE")
        {:ok, decorative}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_descriptions(_image_data, true = _decorative, _opts) do
    {:ok, %{alt_text: "", long_desc: nil, decorative: true, model: nil, cost: nil}}
  end

  defp generate_descriptions(image_data, false, opts) do
    with {:ok, alt} <- Client.vision_completion(image_data, Prompts.for_mode(:alt_text), opts) do
      long = if Keyword.get(opts, :long_desc, false) do
        case Client.vision_completion(image_data, Prompts.for_mode(:long_desc), opts) do
          {:ok, text} -> sanitize(text)
          _ -> nil
        end
      end

      {:ok, %{
        alt_text: sanitize(alt),
        long_desc: long,
        decorative: false,
        model: Keyword.get(opts, :model),
        cost: nil
      }}
    end
  end

  defp sanitize(text) do
    text
    |> String.trim()
    |> String.replace(~r/!\[.*?\]\(.*?\)/, "")
    |> String.replace(~r/\[([^\]]*)\]\(.*?\)/, "\\1")
    |> String.replace(~r/https?:\/\/\S+/, "[link removed]")
  end

  defp get_content_type(headers) do
    Enum.find_value(headers, "application/octet-stream", fn
      {"content-type", value} -> value |> String.split(";") |> hd() |> String.trim()
      _ -> nil
    end)
  end
end
