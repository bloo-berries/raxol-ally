defmodule Ally.SSH.Server do
  @moduledoc """
  Multi-tenant SSH server. Each connecting public key maps to a tenant
  with its own Otari virtual key and budget cap.

  Wraps Raxol.SSH.serve/2 with per-pubkey tenant isolation.
  """

  # TODO: Implement once Raxol dep compiles
  # - Map SSH public keys → tenant IDs
  # - Mint per-tenant Otari virtual keys via the management API
  # - Set budget caps per tenant
  # - Pass tenant context into the Raxol app's init/1
end
