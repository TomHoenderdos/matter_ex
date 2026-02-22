defmodule MatterEx.Commissioning do
  @moduledoc """
  Agent holding transient commissioning state.

  Bridges the commissioning clusters (GeneralCommissioning, OperationalCredentials)
  with the Node/MessageHandler that needs CASE credentials after commissioning completes.

  Supports multiple fabrics. Each fabric is stored by its fabric_index (1..254).
  """

  use Agent

  @default_name __MODULE__

  @type credentials :: %{
    fabric_index: non_neg_integer(),
    noc: binary(),
    icac: binary() | nil,
    private_key: binary(),
    ipk: binary(),
    node_id: integer(),
    fabric_id: integer()
  }

  defp initial_state do
    %{
      armed: false,
      # Pending state for in-progress commissioning
      pending_keypair: nil,
      pending_root_cert: nil,
      # Per-fabric storage: fabric_index => fabric_entry
      fabrics: %{},
      # Tracks the latest fabric that was added (for Node polling)
      last_added_fabric: nil
    }
  end

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    Agent.start_link(fn -> initial_state() end, name: name)
  end

  @spec arm(GenServer.server()) :: :ok
  def arm(name \\ @default_name) do
    Agent.update(name, &Map.put(&1, :armed, true))
  end

  @spec disarm(GenServer.server()) :: :ok
  def disarm(name \\ @default_name) do
    Agent.update(name, &Map.put(&1, :armed, false))
  end

  @spec armed?(GenServer.server()) :: boolean()
  def armed?(name \\ @default_name) do
    Agent.get(name, & &1.armed)
  end

  @spec store_keypair({binary(), binary()}, GenServer.server()) :: :ok
  def store_keypair(keypair, name \\ @default_name) do
    Agent.update(name, &Map.put(&1, :pending_keypair, keypair))
  end

  @spec get_keypair(GenServer.server()) :: {binary(), binary()} | nil
  def get_keypair(name \\ @default_name) do
    Agent.get(name, & &1.pending_keypair)
  end

  @spec store_root_cert(binary(), GenServer.server()) :: :ok
  def store_root_cert(cert, name \\ @default_name) do
    Agent.update(name, &Map.put(&1, :pending_root_cert, cert))
  end

  @spec get_root_cert(GenServer.server()) :: binary() | nil
  def get_root_cert(name \\ @default_name) do
    Agent.get(name, & &1.pending_root_cert)
  end

  @spec store_noc(non_neg_integer(), binary(), binary() | nil, binary(), integer(), integer(), GenServer.server()) :: :ok
  def store_noc(fabric_index, noc, icac, ipk, node_id, fabric_id, name \\ @default_name) do
    require Logger
    Logger.debug("Commissioning.store_noc: fabric=#{fabric_index} node=#{node_id} fabric_id=#{fabric_id} ipk=#{Base.encode16(ipk)}(#{byte_size(ipk)}B)")

    Agent.update(name, fn state ->
      {_pub, priv} = state.pending_keypair
      root_cert = state.pending_root_cert

      if root_cert do
        alias MatterEx.CASE.Messages, as: CASEMessages
        rpk = CASEMessages.extract_public_key(root_cert)
        Logger.debug("Commissioning.store_noc: root_cert=#{byte_size(root_cert)}B root_pub_key=#{if rpk, do: "#{Base.encode16(rpk)}(#{byte_size(rpk)}B)", else: "nil"}")
      else
        Logger.debug("Commissioning.store_noc: root_cert=nil")
      end

      fabric_entry = %{
        fabric_index: fabric_index,
        noc: noc,
        icac: icac,
        ipk: ipk,
        node_id: node_id,
        fabric_id: fabric_id,
        private_key: priv,
        root_cert: root_cert,
        case_admin_subject: nil
      }

      %{state |
        fabrics: Map.put(state.fabrics, fabric_index, fabric_entry),
        last_added_fabric: fabric_index
      }
    end)
  end

  @spec store_admin_subject(non_neg_integer(), non_neg_integer(), GenServer.server()) :: :ok
  def store_admin_subject(fabric_index, subject, name \\ @default_name) do
    Agent.update(name, fn state ->
      fabrics = Map.update!(state.fabrics, fabric_index, fn entry ->
        Map.put(entry, :case_admin_subject, subject)
      end)
      %{state | fabrics: fabrics}
    end)
  end

  @spec get_admin_subject(GenServer.server()) :: non_neg_integer() | nil
  def get_admin_subject(name \\ @default_name) do
    Agent.get(name, fn state ->
      case state.last_added_fabric do
        nil -> nil
        idx -> get_in(state, [:fabrics, idx, :case_admin_subject])
      end
    end)
  end

  @spec complete(GenServer.server()) :: :ok
  def complete(_name \\ @default_name) do
    # No-op now — "commissioned" is implied by having fabrics
    :ok
  end

  @spec commissioned?(GenServer.server()) :: boolean()
  def commissioned?(name \\ @default_name) do
    Agent.get(name, fn state -> map_size(state.fabrics) > 0 end)
  end

  @spec get_credentials(non_neg_integer(), GenServer.server()) :: credentials() | nil
  def get_credentials(fabric_index, name) when is_integer(fabric_index) do
    Agent.get(name, fn state ->
      case Map.get(state.fabrics, fabric_index) do
        nil -> nil
        entry -> build_credentials(entry)
      end
    end)
  end

  # 1-arity: dispatch by argument type
  @spec get_credentials(non_neg_integer() | GenServer.server()) :: credentials() | nil
  def get_credentials(fabric_index) when is_integer(fabric_index) do
    get_credentials(fabric_index, @default_name)
  end

  def get_credentials(name) when is_atom(name) or is_pid(name) do
    Agent.get(name, fn state ->
      case state.last_added_fabric do
        nil ->
          case Map.values(state.fabrics) do
            [] -> nil
            [entry | _] -> build_credentials(entry)
          end

        idx ->
          case Map.get(state.fabrics, idx) do
            nil -> nil
            entry -> build_credentials(entry)
          end
      end
    end)
  end

  # 0-arity: latest credentials with default name
  @spec get_credentials() :: credentials() | nil
  def get_credentials do
    get_credentials(@default_name)
  end

  @spec get_all_credentials(GenServer.server()) :: [credentials()]
  def get_all_credentials(name \\ @default_name) do
    Agent.get(name, fn state ->
      state.fabrics
      |> Map.values()
      |> Enum.map(&build_credentials/1)
    end)
  end

  @spec get_fabric_indices(GenServer.server()) :: [non_neg_integer()]
  def get_fabric_indices(name \\ @default_name) do
    Agent.get(name, fn state -> Map.keys(state.fabrics) end)
  end

  @spec last_added_fabric(GenServer.server()) :: non_neg_integer() | nil
  def last_added_fabric(name \\ @default_name) do
    Agent.get(name, & &1.last_added_fabric)
  end

  @spec clear_last_added(GenServer.server()) :: :ok
  def clear_last_added(name \\ @default_name) do
    Agent.update(name, &Map.put(&1, :last_added_fabric, nil))
  end

  @spec reset(GenServer.server()) :: :ok
  def reset(name \\ @default_name) do
    Agent.update(name, fn _state -> initial_state() end)
  end

  defp build_credentials(entry) do
    %{
      fabric_index: entry.fabric_index,
      noc: entry.noc,
      icac: entry.icac,
      private_key: entry.private_key,
      ipk: entry.ipk,
      node_id: entry.node_id,
      fabric_id: entry.fabric_id,
      case_admin_subject: entry.case_admin_subject,
      root_cert: entry.root_cert
    }
  end
end
