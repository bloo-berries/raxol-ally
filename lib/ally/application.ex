defmodule Ally.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Otari API client pool
      # {Ally.Otari.Client, []},

      # SSH server (multi-tenant, per-pubkey virtual keys)
      # {Ally.SSH.Server, port: ssh_port()},
    ]

    opts = [strategy: :one_for_one, name: Ally.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  def ssh_port do
    System.get_env("ALLY_SSH_PORT", "2222") |> String.to_integer()
  end
end
