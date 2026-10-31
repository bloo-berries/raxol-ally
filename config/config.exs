import Config

config :ally,
  otari_base_url: System.get_env("OTARI_BASE_URL", "http://localhost:8000/api/v1"),
  ssh_port: 2222,
  default_model: "llava-v1.6-mistral-7b",
  fallback_model: "llava-v1.5-7b"

config :logger,
  level: :info

import_config "#{config_env()}.exs"
