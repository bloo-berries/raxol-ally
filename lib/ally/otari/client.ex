defmodule Ally.Otari.Client do
  @moduledoc """
  Client for the self-hosted Otari gateway. Uses the OpenAI-compatible
  chat completions endpoint with vision (image) payloads.
  """

  @default_base_url "http://localhost:8000/api/v1"

  @doc """
  Send an image + text prompt to a vision model through Otari.
  Returns the model's text response.
  """
  @spec vision_completion(map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def vision_completion(image_data, prompt, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, base_url())
    api_key = Keyword.get(opts, :api_key, api_key())
    model = Keyword.get(opts, :model, default_model())

    image_content = encode_image(image_data)

    body = %{
      model: model,
      messages: [
        %{
          role: "user",
          content: [
            %{type: "text", text: prompt},
            image_content
          ]
        }
      ],
      max_tokens: 1024
    }

    case Req.post("#{base_url}/chat/completions",
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Check gateway health."
  @spec health() :: :ok | {:error, term()}
  def health do
    case Req.get("#{base_url()}/health", receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}} -> {:error, {:unhealthy, s}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Config ---

  defp base_url, do: System.get_env("OTARI_BASE_URL", @default_base_url)
  defp api_key, do: System.get_env("OTARI_API_KEY", "")
  defp default_model, do: System.get_env("ALLY_DEFAULT_MODEL", "llava-v1.6-mistral-7b")

  defp encode_image(%{data: data, mime: mime}) do
    %{
      type: "image_url",
      image_url: %{
        url: "data:#{mime};base64,#{Base.encode64(data)}"
      }
    }
  end
end
