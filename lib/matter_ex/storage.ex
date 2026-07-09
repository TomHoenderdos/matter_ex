defmodule MatterEx.Storage do
  @moduledoc """
  Behaviour for persisting Matter operational state (fabric credentials, ACLs,
  group keys) across restarts.

  It is a small key/value contract — the same shape as Matter's reference
  `PersistentStorageDelegate` — so adapters only have to store opaque binaries.
  MatterEx owns the keys and serialization (see `MatterEx.FabricStore`); an
  adapter never needs to understand the payloads.

  A storage backend is configured as `{module, config}`, where `module`
  implements this behaviour and `config` is passed back to every callback (a
  keyword list, map, pid, or registered name — whatever the adapter needs).
  MatterEx ships `MatterEx.Storage.FileSystem`; build your own for ETS, a
  database, a secure element, etc.

  ## Security

  Payloads include **operational private keys and group epoch keys**. An adapter
  is responsible for protecting them at rest. `MatterEx.Storage.FileSystem`
  restricts file permissions but stores plaintext; back this behaviour with
  encrypted storage or a secure element for production.
  """

  @typedoc "Adapter-defined configuration, passed to every callback."
  @type config :: term()

  @typedoc "A `/`-separated key, e.g. `\"matter/fabric/1\"`. Never contains `..`."
  @type key :: String.t()

  @doc "Fetch a value. Returns `:error` when the key is absent."
  @callback get(config, key) :: {:ok, binary()} | :error

  @doc "Store a value, overwriting any existing one."
  @callback put(config, key, value :: binary()) :: :ok | {:error, term()}

  @doc "Delete a key. Deleting an absent key is a no-op success."
  @callback delete(config, key) :: :ok | {:error, term()}

  @doc "List all keys under `prefix` (used to reconcile removed fabrics)."
  @callback keys(config, prefix :: key) :: [key]

  # ── Convenience dispatch on a {module, config} backend ─────────────

  @type backend :: {module(), config()}

  @spec get(backend, key) :: {:ok, binary()} | :error
  def get({mod, config}, key), do: mod.get(config, key)

  @spec put(backend, key, binary()) :: :ok | {:error, term()}
  def put({mod, config}, key, value), do: mod.put(config, key, value)

  @spec delete(backend, key) :: :ok | {:error, term()}
  def delete({mod, config}, key), do: mod.delete(config, key)

  @spec keys(backend, key) :: [key]
  def keys({mod, config}, prefix), do: mod.keys(config, prefix)
end
