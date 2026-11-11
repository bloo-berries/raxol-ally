defmodule Ally.Config do
  @moduledoc """
  Centralized configuration access for Ally.
  Reads from Application config (set via config.exs / runtime.exs),
  with env var overrides for dev convenience.
  """

  def otari_base_url do
    Application.get_env(:ally, :otari_base_url, "http://localhost:8000/api/v1")
  end

  def otari_api_key do
    Application.get_env(:ally, :otari_api_key, "")
  end

  def otari_master_key do
    Application.get_env(:ally, :otari_master_key, "")
  end

  def primary_model do
    Application.get_env(:ally, :primary_model, "llava-v1.6-mistral-7b")
  end

  def fallback_model do
    Application.get_env(:ally, :fallback_model, "llava-v1.5-7b")
  end

  def decorative_model do
    Application.get_env(:ally, :decorative_model, primary_model())
  end

  def ssh_port do
    Application.get_env(:ally, :ssh_port, 2222)
  end

  @doc "Start the SSH surface on boot. Anonymous, loopback-only; see Ally.Application."
  def ssh_enabled? do
    Application.get_env(:ally, :ssh_enabled, false)
  end

  def tenant_budget_usd do
    Application.get_env(:ally, :tenant_budget_usd, 1.00)
  end

  @doc "Otari routing policy name, sent as the model for alt text and long descriptions."
  def routing_policy do
    Application.get_env(:ally, :routing_policy, "ally-failover")
  end

  @doc "Model used for gateway tool calls (code execution). Must support tool calling."
  def tool_model do
    Application.get_env(:ally, :tool_model) || routing_policy()
  end

  @doc "Guardrail profile applied to every completion, or nil to send none."
  def guardrail_profile do
    Application.get_env(:ally, :guardrail_profile)
  end

  @doc "Guardrail mode: \"monitor\" (verdict in header) or \"block\" (403 on violation)."
  def guardrail_mode do
    Application.get_env(:ally, :guardrail_mode, "monitor")
  end
end
