import Config

config :ally,
  otari_base_url: System.get_env("OTARI_BASE_URL", "http://localhost:8000/api/v1"),
  otari_api_key: System.get_env("OTARI_API_KEY", ""),
  otari_master_key: System.get_env("OTARI_MASTER_KEY", ""),
  primary_model: System.get_env("ALLY_PRIMARY_MODEL", "llava-v1.6-mistral-7b"),
  fallback_model: System.get_env("ALLY_FALLBACK_MODEL", "llava-v1.5-7b"),
  decorative_model: System.get_env("ALLY_DECORATIVE_MODEL"),
  ssh_port: System.get_env("ALLY_SSH_PORT", "2222") |> String.to_integer(),
  ssh_enabled: System.get_env("ALLY_SSH_ENABLED", "false") == "true",
  tenant_budget_usd: System.get_env("ALLY_TENANT_BUDGET_USD", "1.00") |> String.to_float(),
  routing_policy: System.get_env("ALLY_ROUTING_POLICY", "ally-failover"),
  tool_model: System.get_env("ALLY_TOOL_MODEL"),
  guardrail_profile: System.get_env("ALLY_GUARDRAIL_PROFILE"),
  guardrail_mode: System.get_env("ALLY_GUARDRAIL_MODE", "monitor")

if config_env() == :prod do
  if System.get_env("OTARI_API_KEY") in [nil, ""] do
    raise "OTARI_API_KEY is required in production"
  end
end
