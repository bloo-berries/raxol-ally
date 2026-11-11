defmodule Ally.Audit.Scanner do
  @moduledoc """
  URL audit: fetches a web page, finds images missing alt text,
  generates WCAG-compliant descriptions for each, and produces a linear
  screen-reader summary of the page.

  Image discovery uses Req + Floki (the HTML must be parsed for `<img>`
  attributes). The page summary is produced by a model that reads the page
  through Otari's gateway-run `otari_web_fetch` tool; the fetch Otari ran is
  read back from `otari_tool_calls`.
  """

  require Logger

  alias Ally.Otari.Client
  alias Ally.Vision.Pipeline

  @type audit_result :: %{
          url: String.t(),
          total_images: non_neg_integer(),
          missing_alt: non_neg_integer(),
          decorative_count: non_neg_integer(),
          images: list(image_finding()),
          summary: String.t(),
          page_summary: page_summary()
        }

  @type image_finding :: %{
          src: String.t(),
          original_alt: String.t() | nil,
          status: :missing | :empty | :present | :decorative,
          generated_alt: String.t() | nil,
          error: String.t() | nil
        }

  @type page_summary :: %{
          text: String.t() | nil,
          fetches: list(%{url: String.t() | nil, status: String.t() | nil}),
          model: String.t() | nil,
          provider: String.t() | nil,
          usage: Client.usage() | nil,
          request_id: String.t() | nil,
          guardrails: list(Client.guardrail_verdict()),
          error: String.t() | nil
        }

  @fetch_tool %{type: "otari_web_fetch"}

  @doc """
  Audit a URL for image accessibility. Fetches the page, finds all <img> tags,
  identifies those missing or empty alt attributes, and generates descriptions.
  """
  @spec audit(String.t(), keyword()) :: {:ok, audit_result()} | {:error, term()}
  def audit(url, opts \\ []) do
    max_images = Keyword.get(opts, :max_images, 10)

    with {:ok, html} <- fetch_page(url),
         {:ok, images} <- extract_images(html, url),
         findings <- analyze_images(images, max_images, opts) do
      missing = Enum.count(findings, &(&1.status in [:missing, :empty]))
      decorative = Enum.count(findings, &(&1.status == :decorative))

      {:ok,
       %{
         url: url,
         total_images: length(images),
         missing_alt: missing,
         decorative_count: decorative,
         images: findings,
         summary: build_summary(url, length(images), missing, decorative),
         page_summary: summarize_page(url, opts)
       }}
    end
  end

  @doc """
  Quick scan: just count images and missing alt text, no description generation.
  """
  @spec quick_scan(String.t()) :: {:ok, map()} | {:error, term()}
  def quick_scan(url) do
    with {:ok, html} <- fetch_page(url),
         {:ok, images} <- extract_images(html, url) do
      missing =
        Enum.count(images, fn img ->
          alt = img.alt
          alt == nil or alt == ""
        end)

      {:ok,
       %{
         url: url,
         total_images: length(images),
         missing_alt: missing,
         has_issues: missing > 0
       }}
    end
  end

  # --- Private ---

  defp fetch_page(url) do
    case Req.get(url,
           max_retries: 1,
           receive_timeout: 15_000,
           headers: [{"user-agent", "Ally/0.1 (accessibility auditor)"}]
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp summarize_page(url, opts) do
    prompt = """
    Use the web fetch tool to read this page: #{url}

    Then write a linear summary for a screen reader user, in plain text with no
    markdown and no bullet symbols, at most 8 short lines:
    1. The page title and what the page is for
    2. The main headings, in reading order
    3. The main navigation landmarks (menus, search, footer links)
    """

    request_opts =
      opts
      |> Keyword.take([:api_key, :base_url, :model])
      |> Keyword.merge(tools: [@fetch_tool], max_tokens: 600)

    case Client.chat_completion(prompt, request_opts) do
      {:ok, result} ->
        %{
          text: Pipeline.sanitize(result.text),
          fetches: fetches(result.tool_calls),
          model: result.model,
          provider: result.provider,
          usage: result.usage,
          request_id: result.request_id,
          guardrails: result.guardrails,
          error: nil
        }

      {:error, reason} ->
        Logger.warning("Page summary via Otari web fetch failed: #{inspect(reason)}")

        %{
          text: nil,
          fetches: [],
          model: nil,
          provider: nil,
          usage: nil,
          request_id: nil,
          guardrails: [],
          error: inspect(reason)
        }
    end
  end

  defp fetches(tool_calls) do
    tool_calls
    |> Enum.filter(&(&1["type"] == "web_fetch"))
    |> Enum.map(&%{url: &1["url"], status: &1["status"]})
  end

  defp extract_images(html, base_url) do
    images =
      html
      |> Floki.parse_document!()
      |> Floki.find("img")
      |> Enum.map(fn {"img", attrs, _children} ->
        attr_map = Map.new(attrs)
        src = resolve_url(attr_map["src"], base_url)
        alt = attr_map["alt"]

        %{src: src, alt: alt, role: attr_map["role"]}
      end)
      |> Enum.filter(&(&1.src != nil))

    {:ok, images}
  end

  defp analyze_images(images, max_images, opts) do
    images
    |> Enum.take(max_images)
    |> Enum.map(fn img ->
      status = classify_status(img)

      case status do
        s when s in [:missing, :empty] ->
          generate_for_image(img, opts)

        :present ->
          %{
            src: img.src,
            original_alt: img.alt,
            status: :present,
            generated_alt: nil,
            error: nil
          }

        :decorative ->
          %{
            src: img.src,
            original_alt: img.alt,
            status: :decorative,
            generated_alt: nil,
            error: nil
          }
      end
    end)
  end

  defp classify_status(%{role: "presentation"}), do: :decorative
  defp classify_status(%{role: "none"}), do: :decorative
  defp classify_status(%{alt: nil}), do: :missing
  defp classify_status(%{alt: ""}), do: :empty
  defp classify_status(_), do: :present

  defp generate_for_image(img, opts) do
    case Pipeline.alt_text(img.src, opts) do
      {:ok, result} ->
        %{
          src: img.src,
          original_alt: img.alt,
          status: if(img.alt == nil, do: :missing, else: :empty),
          generated_alt: result.alt_text,
          error: nil
        }

      {:error, reason} ->
        %{
          src: img.src,
          original_alt: img.alt,
          status: if(img.alt == nil, do: :missing, else: :empty),
          generated_alt: nil,
          error: inspect(reason)
        }
    end
  end

  defp resolve_url(nil, _base), do: nil
  defp resolve_url("data:" <> _, _base), do: nil
  defp resolve_url(src, base_url), do: base_url |> URI.merge(src) |> URI.to_string()

  defp build_summary(url, total, missing, decorative) do
    issues =
      cond do
        missing == 0 -> "All images have alt text."
        missing == 1 -> "1 image is missing alt text."
        true -> "#{missing} images are missing alt text."
      end

    "Audited #{url}: #{total} images found. #{issues}" <>
      if(decorative > 0, do: " #{decorative} decorative.", else: "")
  end
end
