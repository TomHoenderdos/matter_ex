defmodule Matterlix.Node do
  @moduledoc """
  Matter device node — GenServer wrapping MessageHandler + UDP socket.

  Opens a UDP socket, receives datagrams, routes them through the
  full protocol stack (MessageHandler → SecureChannel → ExchangeManager → IM),
  and sends response datagrams back to the peer.

  The Device supervisor must already be running before starting the node.

  ## Example

      # Start device first
      MyDevice.start_link()

      # Start node
      {:ok, node} = Matterlix.Node.start_link(
        device: MyDevice,
        passcode: 20202021,
        salt: salt,
        iterations: 1000,
        port: 5540
      )

      # Node is now listening on UDP port 5540
  """

  use GenServer

  require Logger

  alias Matterlix.{Commissioning, MessageHandler}

  @sub_check_interval 1000

  defmodule State do
    @moduledoc false
    defstruct [:handler, :socket, :port, :peer, :mdns, :commissioning_instance]
  end

  # ── Public API ───────────────────────────────────────────────────

  @doc """
  Start the node.

  Required options:
  - `:device` — device module (must already be started)
  - `:passcode` — commissioning passcode
  - `:salt` — PBKDF2 salt
  - `:iterations` — PBKDF2 iterations

  Optional:
  - `:port` — UDP port (default 5540, use 0 for OS-assigned)
  - `:name` — GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Get the UDP port the node is listening on.

  Useful when started with `port: 0` (OS-assigned port).
  """
  @spec port(GenServer.server()) :: non_neg_integer()
  def port(server) do
    GenServer.call(server, :get_port)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────

  @impl true
  def init(opts) do
    udp_port = Keyword.get(opts, :port, 5540)

    # Start commissioning agent if not already running
    if !Process.whereis(Commissioning) do
      Commissioning.start_link()
    end

    case :gen_udp.open(udp_port, [:binary, {:active, true}]) do
      {:ok, socket} ->
        {:ok, assigned_port} = :inet.port(socket)

        # Generate random session ID for PASE (1..65534)
        local_session_id = :rand.uniform(65534)

        handler = MessageHandler.new(
          device: Keyword.fetch!(opts, :device),
          passcode: Keyword.fetch!(opts, :passcode),
          salt: Keyword.fetch!(opts, :salt),
          iterations: Keyword.fetch!(opts, :iterations),
          local_session_id: local_session_id
        )

        Logger.info("Matter node listening on UDP port #{assigned_port}")
        Process.send_after(self(), :check_subscriptions, @sub_check_interval)

        {:ok, %State{
          handler: handler,
          socket: socket,
          port: assigned_port,
          peer: nil,
          mdns: Keyword.get(opts, :mdns),
          commissioning_instance: Keyword.get(opts, :commissioning_instance)
        }}

      {:error, reason} ->
        Logger.error("Failed to open UDP port #{udp_port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, state.port, state}
  end

  @impl true
  def handle_info({:udp, _socket, ip, port, data}, state) do
    peer = {ip, port}
    Logger.debug("UDP RX #{byte_size(data)}B from #{:inet.ntoa(ip)}:#{port}: #{Base.encode16(binary_part(data, 0, min(32, byte_size(data))))}")
    {actions, handler} = MessageHandler.handle_frame(state.handler, data)
    state = %{state | handler: handler, peer: peer}
    state = process_actions(actions, state)
    {:noreply, state}
  end

  def handle_info({:mrp_timeout, session_id, exchange_id, attempt}, state) do
    {action, handler} = MessageHandler.handle_mrp_timeout(
      state.handler, session_id, exchange_id, attempt
    )

    state = %{state | handler: handler}

    state =
      case action do
        {:send, frame} ->
          send_to_peer(state, frame)
          state

        nil ->
          state
      end

    {:noreply, state}
  end

  def handle_info(:check_subscriptions, state) do
    {actions, handler} = MessageHandler.check_subscriptions(state.handler)
    {handler, state} = maybe_update_case(handler, state)
    state = %{state | handler: handler}
    state = process_actions(actions, state)
    Process.send_after(self(), :check_subscriptions, @sub_check_interval)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      :gen_udp.close(state.socket)
    end

    :ok
  end

  # ── Private ──────────────────────────────────────────────────────

  defp process_actions(actions, state) do
    Enum.reduce(actions, state, fn action, state ->
      case action do
        {:send, frame} ->
          send_to_peer(state, frame)
          state

        {:schedule_mrp, session_id, exchange_id, attempt, timeout_ms} ->
          Process.send_after(
            self(),
            {:mrp_timeout, session_id, exchange_id, attempt},
            timeout_ms
          )
          state

        {:session_established, session_id} ->
          Logger.info("Session #{session_id} established with peer #{inspect(state.peer)}")
          state

        {:session_closed, session_id} ->
          Logger.info("Session #{session_id} closed")
          state

        {:error, reason} ->
          Logger.warning("Protocol error: #{inspect(reason)}")
          state
      end
    end)
  end

  defp maybe_update_case(handler, state) do
    case Commissioning.last_added_fabric() do
      nil ->
        {handler, state}

      fabric_index ->
        creds = Commissioning.get_credentials(fabric_index)

        if creds do
          Logger.info("Commissioning complete for fabric #{fabric_index} — enabling CASE")
          opts = Keyword.new(Map.put(creds, :fabric_index, fabric_index))
          handler = MessageHandler.update_case(handler, opts)

          Commissioning.clear_last_added()

          # Write initial admin ACL entry if we have an admin subject
          if handler.device && creds[:case_admin_subject] do
            write_initial_acl(handler.device, creds.case_admin_subject, fabric_index)
          end

          # Transition mDNS: withdraw commissioning, advertise operational
          transition_mdns(state, creds)

          {handler, state}
        else
          {handler, state}
        end
    end
  end

  defp write_initial_acl(device, admin_subject, fabric_index) do
    acl_name = device.__process_name__(0, :access_control)

    if acl_name && Process.whereis(acl_name) do
      admin_entry = %{
        privilege: 5,
        auth_mode: 2,
        subjects: [admin_subject],
        targets: nil,
        fabric_index: fabric_index
      }

      GenServer.call(acl_name, {:write_attribute, :acl, [admin_entry]})
    end
  end

  defp transition_mdns(%State{mdns: nil}, _creds), do: :ok

  defp transition_mdns(%State{mdns: mdns, commissioning_instance: inst, port: port}, creds) do
    alias Matterlix.CASE.Messages, as: CASEMessages
    alias Matterlix.MDNS

    # Withdraw commissioning advertisement
    if inst, do: MDNS.withdraw(mdns, inst)

    # Compute compressed fabric ID from root cert
    root_pub = if creds[:root_cert], do: CASEMessages.extract_public_key(creds.root_cert)

    if root_pub && creds[:fabric_id] && creds[:node_id] do
      cfid = MDNS.compressed_fabric_id(root_pub, creds.fabric_id)

      service = MDNS.operational_service(
        port: port,
        compressed_fabric_id: cfid,
        node_id: creds.node_id
      )

      MDNS.advertise(mdns, service)
      Logger.info("mDNS: transitioned to operational (_matter._tcp)")
    end
  end

  defp send_to_peer(%State{socket: socket, peer: {ip, port}}, frame) do
    Logger.debug("UDP TX #{byte_size(frame)}B to #{:inet.ntoa(ip)}:#{port}: #{Base.encode16(binary_part(frame, 0, min(32, byte_size(frame))))}")
    :gen_udp.send(socket, ip, port, frame)
  end

  defp send_to_peer(_state, _frame) do
    Logger.warning("Dropping frame: no peer address known")
    :ok
  end
end
