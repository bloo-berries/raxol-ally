defmodule Ally.MCP.Server do
  @moduledoc """
  MCP server that exposes Ally's accessibility tools.
  External agents can drive Ally via MCP to:
  - Describe images (generate alt text)
  - Audit URLs for missing alt text
  - Check WCAG contrast ratios

  Built on Raxol's MCP infrastructure.
  """

  alias Ally.Vision.Pipeline
  alias Ally.Audit.Scanner
  alias Ally.Tools.ContrastChecker

  @tools [
    %{
      name: "describe_image",
      description:
        "Generate WCAG-compliant alt text for an image. Returns alt text, decorative classification, and optionally a long description.",
      inputSchema: %{
        type: "object",
        properties: %{
          image_source: %{
            type: "string",
            description: "Image file path or URL"
          },
          long_desc: %{
            type: "boolean",
            description: "Whether to generate a detailed long description (default: false)"
          }
        },
        required: ["image_source"]
      }
    },
    %{
      name: "audit_url",
      description:
        "Audit a web page for image accessibility. Finds images missing alt text and generates candidates.",
      inputSchema: %{
        type: "object",
        properties: %{
          url: %{
            type: "string",
            description: "URL to audit"
          },
          max_images: %{
            type: "integer",
            description: "Maximum images to process (default: 10)"
          }
        },
        required: ["url"]
      }
    },
    %{
      name: "check_contrast",
      description: "Check WCAG contrast ratio between foreground and background colors.",
      inputSchema: %{
        type: "object",
        properties: %{
          foreground: %{
            type: "string",
            description: "Foreground color as hex (e.g., '#333333')"
          },
          background: %{
            type: "string",
            description: "Background color as hex (e.g., '#FFFFFF')"
          }
        },
        required: ["foreground", "background"]
      }
    }
  ]

  @doc "Return the list of MCP tool definitions."
  @spec tools() :: list(map())
  def tools, do: @tools

  @doc "Handle an MCP tool call."
  @spec handle_tool_call(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def handle_tool_call("describe_image", %{"image_source" => source} = args) do
    long_desc = Map.get(args, "long_desc", false)

    case Pipeline.describe(source, long_desc: long_desc) do
      {:ok, result} ->
        response =
          if result.decorative do
            "Image is decorative (purely aesthetic, no meaningful content)."
          else
            parts = ["Alt text: #{result.alt_text}"]

            parts =
              if result.long_desc,
                do: parts ++ ["Long description: #{result.long_desc}"],
                else: parts

            parts = if result.model, do: parts ++ ["Model: #{result.model}"], else: parts
            Enum.join(parts, "\n\n")
          end

        {:ok, response}

      {:error, reason} ->
        {:error, "Failed to describe image: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("audit_url", %{"url" => url} = args) do
    max_images = Map.get(args, "max_images", 10)

    case Scanner.audit(url, max_images: max_images) do
      {:ok, result} ->
        findings =
          result.images
          |> Enum.map(fn img ->
            status_str = Atom.to_string(img.status)
            line = "- [#{status_str}] #{img.src}"

            line =
              if img.generated_alt do
                line <> "\n  Suggested: #{img.generated_alt}"
              else
                line
              end

            if img.error do
              line <> "\n  Error: #{img.error}"
            else
              line
            end
          end)
          |> Enum.join("\n")

        page =
          case result.page_summary do
            %{text: nil, error: error} -> "Page summary unavailable: #{error}"
            %{text: text} -> "Page summary (via Otari web fetch):\n#{text}"
          end

        {:ok, "#{result.summary}\n\nFindings:\n#{findings}\n\n#{page}"}

      {:error, reason} ->
        {:error, "Failed to audit URL: #{inspect(reason)}"}
    end
  end

  def handle_tool_call("check_contrast", %{"foreground" => fg, "background" => bg}) do
    case ContrastChecker.check_contrast(fg, bg) do
      {:ok, result} ->
        {:ok, ContrastChecker.format(result)}

      {:error, reason} ->
        {:error, "Failed to check contrast: #{inspect(reason)}"}
    end
  end

  def handle_tool_call(tool_name, _args) do
    {:error, "Unknown tool: #{tool_name}"}
  end
end
