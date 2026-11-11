defmodule Ally.Tools.ContrastChecker do
  @moduledoc """
  WCAG contrast ratio checking via Otari's code execution sandbox.
  Declares the gateway-run `otari_code_execution` tool; Otari runs the
  Python the model writes and reports each run in `otari_tool_calls`.
  """

  alias Ally.Otari.Client

  @code_exec_tool %{type: "otari_code_execution"}

  @type execution :: %{
          code: String.t() | nil,
          stdout: String.t() | nil,
          stderr: String.t() | nil,
          exit_code: integer() | nil,
          status: String.t() | nil
        }

  @type result :: %{
          text: String.t() | nil,
          executions: list(execution()),
          model: String.t() | nil,
          provider: String.t() | nil,
          usage: Client.usage() | nil,
          request_id: String.t() | nil,
          guardrails: list(Client.guardrail_verdict())
        }

  @doc """
  Check WCAG contrast ratio between two colors.
  Uses Otari code execution to compute the ratio and determine pass/fail.

  Colors should be hex strings like "#FFFFFF" and "#000000".
  """
  @spec check_contrast(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def check_contrast(foreground, background, opts \\ []) do
    prompt = """
    Calculate the WCAG 2.2 contrast ratio between these two colors:
    - Foreground: #{foreground}
    - Background: #{background}

    Use the code execution tool to run Python code that:
    1. Converts both hex colors to relative luminance using the sRGB formula
    2. Calculates the contrast ratio (lighter + 0.05) / (darker + 0.05)
    3. Determines if it passes WCAG AA (>= 4.5:1 for normal text, >= 3:1 for large text)
    4. Determines if it passes WCAG AAA (>= 7:1 for normal text, >= 4.5:1 for large text)
    5. Prints the ratio and the pass/fail results

    Then return the results as a clear one-paragraph summary.
    """

    run(prompt, opts)
  end

  @doc """
  Extract metadata from an image URL using code execution.
  Asks the model to fetch and analyze image properties.
  """
  @spec extract_metadata(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def extract_metadata(image_url, opts \\ []) do
    prompt = """
    Use the code execution tool to run Python code that:
    1. Downloads the image from: #{image_url}
    2. Opens it with PIL/Pillow
    3. Extracts: dimensions, format, color mode, DPI if available
    4. Checks for EXIF data (especially any existing description/caption fields)
    5. Computes average brightness to help determine if the image is decorative
    6. Prints the metadata

    Then return the metadata as a structured summary.
    """

    run(prompt, opts)
  end

  @doc "Render a result as screen-reader-friendly lines: model summary, then sandbox output."
  @spec format(result()) :: String.t()
  def format(%{text: text, executions: executions}) do
    summary = text || "No summary returned."

    case executions do
      [] ->
        summary <> "\n\n(No code was executed by the gateway.)"

      runs ->
        outputs =
          Enum.map(runs, fn run ->
            out = String.trim(run.stdout || "")
            err = String.trim(run.stderr || "")

            [
              "Sandbox run (exit #{inspect(run.exit_code)}, #{run.status}):",
              if(out != "", do: out, else: nil),
              if(err != "", do: "stderr: " <> err, else: nil)
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("\n")
          end)

        summary <> "\n\n" <> Enum.join(outputs, "\n\n")
    end
  end

  # --- Private ---

  defp run(prompt, opts) do
    with {:ok, result} <-
           Client.chat_completion(prompt, Keyword.merge(opts, tools: [@code_exec_tool])) do
      {:ok,
       %{
         text: result.text,
         executions: executions(result.tool_calls),
         model: result.model,
         provider: result.provider,
         usage: result.usage,
         request_id: result.request_id,
         guardrails: result.guardrails
       }}
    end
  end

  defp executions(tool_calls) do
    tool_calls
    |> Enum.filter(&(&1["type"] == "code_execution"))
    |> Enum.map(fn call ->
      %{
        code: call["code"],
        stdout: call["stdout"],
        stderr: call["stderr"],
        exit_code: call["exit_code"],
        status: call["status"]
      }
    end)
  end
end
