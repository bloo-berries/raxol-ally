import Config

config :ally,
  otari_base_url: "http://localhost:8000/api/v1",
  otari_api_key: "",
  otari_master_key: "",
  primary_model: "llava-v1.6-mistral-7b",
  fallback_model: "llava-v1.5-7b",
  decorative_model: "llava-v1.6-mistral-7b",
  ssh_port: 2222,
  ssh_enabled: false,
  tenant_budget_usd: 1.00,
  routing_policy: "ally-failover",
  tool_model: nil,
  guardrail_profile: nil,
  guardrail_mode: "monitor"

config :logger,
  level: :info

import_config "#{config_env()}.exs"
