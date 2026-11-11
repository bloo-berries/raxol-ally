defmodule Ally.Application do
  @moduledoc false
  use Application

  alias Ally.Config

  @impl true
  def start(_type, _args) do
    children =
      [
        # Per-tenant SSH key -> virtual key registry
        {Ally.SSH.Server, []}
      ] ++ ssh_children()

    opts = [strategy: :one_for_one, name: Ally.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Serves the TUI over SSH on loopback: `ssh localhost -p $ALLY_SSH_PORT`.
  # Anonymous for the demo, so Raxol requires every resource cap explicitly
  # and refuses non-loopback binds without :anonymous_public.
  defp ssh_children do
    if Config.ssh_enabled?() do
      [
        %{
          id: Ally.SSH.Listener,
          start:
            {Raxol.SSH, :serve,
             [
               Ally.App,
               [
                 port: Config.ssh_port(),
                 allow_anonymous: true,
                 max_connections: 10,
                 max_per_ip: 4,
                 idle_timeout: :timer.minutes(10),
                 max_session_duration: :timer.hours(1)
               ]
             ]}
        }
      ]
    else
      []
    end
  end
end
