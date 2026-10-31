import Config

if config_env() == :prod do
  config :ally,
    otari_base_url: System.fetch_env!("OTARI_BASE_URL"),
    otari_api_key: System.fetch_env!("OTARI_API_KEY"),
    ssh_port: System.get_env("ALLY_SSH_PORT", "2222") |> String.to_integer(),
    default_model: System.get_env("ALLY_DEFAULT_MODEL", "llava-v1.6-mistral-7b"),
    fallback_model: System.get_env("ALLY_FALLBACK_MODEL", "llava-v1.5-7b")
end
