defmodule Matterlix.Commissioning do
  @moduledoc """
  Agent holding transient commissioning state.

  Bridges the commissioning clusters (GeneralCommissioning, OperationalCredentials)
  with the Node/MessageHandler that needs CASE credentials after commissioning completes.

  Uses a fixed registered name by default.
  """

  use Agent

  @default_name __MODULE__

  @type credentials :: %{
    noc: binary(),
    private_key: binary(),
    ipk: binary(),
    node_id: integer(),
    fabric_id: integer()
  }

  defp initial_state do
    %{
      armed: false,
      keypair: nil,
      root_cert: nil,
      noc: nil,
      ipk: nil,
      node_id: nil,
      fabric_id: nil,
      commissioned: false,
      case_admin_subject: nil
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
    Agent.update(name, &Map.put(&1, :keypair, keypair))
  end

  @spec get_keypair(GenServer.server()) :: {binary(), binary()} | nil
  def get_keypair(name \\ @default_name) do
    Agent.get(name, & &1.keypair)
  end

  @spec store_root_cert(binary(), GenServer.server()) :: :ok
  def store_root_cert(cert, name \\ @default_name) do
    Agent.update(name, &Map.put(&1, :root_cert, cert))
  end

  @spec get_root_cert(GenServer.server()) :: binary() | nil
  def get_root_cert(name \\ @default_name) do
    Agent.get(name, & &1.root_cert)
  end

  @spec store_noc(binary(), binary(), integer(), integer(), GenServer.server()) :: :ok
  def store_noc(noc, ipk, node_id, fabric_id, name \\ @default_name) do
    Agent.update(name, fn state ->
      %{state | noc: noc, ipk: ipk, node_id: node_id, fabric_id: fabric_id}
    end)
  end

  @spec store_admin_subject(non_neg_integer(), GenServer.server()) :: :ok
  def store_admin_subject(subject, name \\ @default_name) do
    Agent.update(name, &Map.put(&1, :case_admin_subject, subject))
  end

  @spec get_admin_subject(GenServer.server()) :: non_neg_integer() | nil
  def get_admin_subject(name \\ @default_name) do
    Agent.get(name, & &1.case_admin_subject)
  end

  @spec complete(GenServer.server()) :: :ok
  def complete(name \\ @default_name) do
    Agent.update(name, &Map.put(&1, :commissioned, true))
  end

  @spec commissioned?(GenServer.server()) :: boolean()
  def commissioned?(name \\ @default_name) do
    Agent.get(name, & &1.commissioned)
  end

  @spec get_credentials(GenServer.server()) :: credentials() | nil
  def get_credentials(name \\ @default_name) do
    Agent.get(name, fn state ->
      if state.commissioned && state.noc && state.keypair do
        {_pub, priv} = state.keypair

        %{
          noc: state.noc,
          private_key: priv,
          ipk: state.ipk,
          node_id: state.node_id,
          fabric_id: state.fabric_id,
          case_admin_subject: state.case_admin_subject,
          root_cert: state.root_cert
        }
      end
    end)
  end

  @spec reset(GenServer.server()) :: :ok
  def reset(name \\ @default_name) do
    Agent.update(name, fn _state -> initial_state() end)
  end
end
