defmodule Ally.SSH.Server do
  @moduledoc """
  Multi-tenant SSH server. Each connecting public key maps to a tenant
  with its own Otari virtual key and budget cap.

  Wraps Raxol.SSH.serve/2 with per-pubkey tenant isolation.
  Tenants are tracked in an ETS table; virtual keys are minted
  on first connection via the Otari management API.
  """

  use GenServer

  require Logger

  alias Ally.Config
  alias Ally.Otari.Client

  @table :ally_tenants

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Look up or create a tenant for the given SSH public key fingerprint."
  @spec get_or_create_tenant(String.t()) :: {:ok, map()} | {:error, term()}
  def get_or_create_tenant(fingerprint) do
    case :ets.lookup(@table, fingerprint) do
      [{^fingerprint, tenant}] ->
        {:ok, tenant}

      [] ->
        GenServer.call(__MODULE__, {:create_tenant, fingerprint}, 15_000)
    end
  end

  @doc "Get tenant context for passing into Ally.App.init/1."
  @spec tenant_context(String.t()) :: map()
  def tenant_context(fingerprint) do
    case get_or_create_tenant(fingerprint) do
      {:ok, tenant} ->
        %{
          tenant_id: tenant.id,
          api_key: tenant.api_key,
          budget_id: tenant.budget_id,
          fingerprint: fingerprint
        }

      {:error, reason} ->
        Logger.error("Failed to create tenant for #{fingerprint}: #{inspect(reason)}")

        %{
          tenant_id: nil,
          api_key: Config.otari_api_key(),
          budget_id: nil,
          fingerprint: fingerprint
        }
    end
  end

  @doc "List all active tenants."
  @spec list_tenants() :: list(map())
  def list_tenants do
    :ets.tab2list(@table)
    |> Enum.map(fn {_fp, tenant} -> tenant end)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:create_tenant, fingerprint}, _from, state) do
    # Double-check after acquiring the lock
    case :ets.lookup(@table, fingerprint) do
      [{^fingerprint, tenant}] ->
        {:reply, {:ok, tenant}, state}

      [] ->
        result = mint_tenant(fingerprint)

        case result do
          {:ok, tenant} ->
            :ets.insert(@table, {fingerprint, tenant})
            Logger.info("Created tenant #{tenant.id} for fingerprint #{truncate_fp(fingerprint)}")
            {:reply, {:ok, tenant}, state}

          {:error, reason} ->
            # Fallback: create a local-only tenant with the global API key
            tenant = fallback_tenant(fingerprint)
            :ets.insert(@table, {fingerprint, tenant})

            Logger.warning(
              "Otari key minting failed (#{inspect(reason)}), using fallback for #{truncate_fp(fingerprint)}"
            )

            {:reply, {:ok, tenant}, state}
        end
    end
  end

  # --- Private ---

  defp mint_tenant(fingerprint) do
    tenant_id = "tenant-#{short_id(fingerprint)}"
    budget_id = "budget-#{tenant_id}"
    budget_usd = Config.tenant_budget_usd()

    with {:ok, _budget} <-
           Client.create_budget(%{
             "name" => "Ally tenant #{tenant_id}",
             "max_budget" => budget_usd,
             "budget_duration_sec" => 86_400
           }),
         {:ok, key_resp} <-
           Client.create_virtual_key(%{
             "key_name" => "ally-#{tenant_id}",
             "metadata" => %{"tenant_id" => tenant_id, "fingerprint" => truncate_fp(fingerprint)},
             "allowed_models" =>
               Enum.uniq([
                 Config.routing_policy(),
                 Config.tool_model(),
                 Config.primary_model(),
                 Config.fallback_model(),
                 Config.decorative_model()
               ])
           }) do
      {:ok,
       %{
         id: tenant_id,
         fingerprint: fingerprint,
         api_key: key_resp["key"],
         budget_id: budget_id,
         budget_usd: budget_usd,
         created_at: DateTime.utc_now()
       }}
    end
  end

  defp fallback_tenant(fingerprint) do
    %{
      id: "local-#{short_id(fingerprint)}",
      fingerprint: fingerprint,
      api_key: Config.otari_api_key(),
      budget_id: nil,
      budget_usd: nil,
      created_at: DateTime.utc_now()
    }
  end

  defp short_id(fingerprint) do
    fingerprint
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
    |> String.slice(0..7)
  end

  defp truncate_fp(fingerprint) do
    String.slice(fingerprint, 0..15) <> "..."
  end
end
