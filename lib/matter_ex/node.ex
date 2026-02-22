defmodule MatterEx.Node do
  @moduledoc """
  Matter device node — GenServer wrapping MessageHandler + UDP/TCP sockets.

  Opens a UDP socket and a TCP listener, receives messages, routes them through the
  full protocol stack (MessageHandler → SecureChannel → ExchangeManager → IM),
  and sends responses back to the peer via the same transport.

  TCP uses 4-byte little-endian length-prefixed framing. MRP retransmits are
  skipped for TCP sessions since TCP provides reliable delivery.

  The Device supervisor must already be running before starting the node.

  ## Example

      # Start device first
      MyDevice.start_link()

      # Start node (listens on both UDP and TCP)
      {:ok, node} = MatterEx.Node.start_link(
        device: MyDevice,
        passcode: 20202021,
        salt: salt,
        iterations: 1000,
        port: 5540
      )
  """

  use GenServer

  require Logger

  alias MatterEx.{Commissioning, MessageHandler}
  alias MatterEx.Protocol.MessageCodec.Header
  alias MatterEx.Transport.TCP, as: TCPFraming

  @sub_check_interval 1000

  defmodule State do
    @moduledoc false
    defstruct [
      :handler,
      :socket,
      :port,
      :tcp_listener,
      :mdns,
      :commissioning_instance,
      # Current transport for the frame being processed
      current_transport: nil,
      # Per-session transport: session_id => {:udp, {ip, port}} | {:tcp, tcp_socket}
      session_transports: %{},
      # TCP per-connection buffers: tcp_socket => binary
      tcp_buffers: %{}
    ]
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
  - `:port` — UDP/TCP port (default 5540, use 0 for OS-assigned)
  - `:name` — GenServer name
  - `:tcp` — enable TCP listener (default true)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Get the port the node is listening on (UDP and TCP share the same port).

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
    tcp_enabled = Keyword.get(opts, :tcp, true)

    # Start commissioning agent if not already running
    if !Process.whereis(Commissioning) do
      Commissioning.start_link()
    end

    case :gen_udp.open(udp_port, [:binary, {:active, true}]) do
      {:ok, socket} ->
        {:ok, assigned_port} = :inet.port(socket)

        # Start TCP listener on the same port number
        tcp_listener = if tcp_enabled, do: start_tcp_listener(assigned_port)

        # Generate random session ID for PASE (1..65534)
        local_session_id = :rand.uniform(65534)

        handler = MessageHandler.new(
          device: Keyword.fetch!(opts, :device),
          passcode: Keyword.fetch!(opts, :passcode),
          salt: Keyword.fetch!(opts, :salt),
          iterations: Keyword.fetch!(opts, :iterations),
          local_session_id: local_session_id
        )

        transport_msg = if tcp_listener, do: "UDP+TCP", else: "UDP"
        Logger.info("Matter node listening on #{transport_msg} port #{assigned_port}")
        Process.send_after(self(), :check_subscriptions, @sub_check_interval)

        {:ok, %State{
          handler: handler,
          socket: socket,
          port: assigned_port,
          tcp_listener: tcp_listener,
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

  # ── UDP messages ────────────────────────────────────────────────

  @impl true
  def handle_info({:udp, _socket, ip, port, data}, state) do
    transport = {:udp, {ip, port}}
    Logger.debug("UDP RX #{byte_size(data)}B from #{:inet.ntoa(ip)}:#{port}")
    state = %{state | current_transport: transport}
    state = update_peer_transport(state, data, transport)
    {actions, handler} = MessageHandler.handle_frame(state.handler, data)
    state = %{state | handler: handler}
    state = process_actions(actions, state)
    {:noreply, state}
  end

  # ── TCP connection acceptance ────────────────────────────────────

  def handle_info({:tcp_accepted, tcp_socket}, state) do
    {:ok, {ip, port}} = :inet.peername(tcp_socket)
    Logger.info("TCP connection accepted from #{:inet.ntoa(ip)}:#{port}")
    tcp_buffers = Map.put(state.tcp_buffers, tcp_socket, <<>>)
    {:noreply, %{state | tcp_buffers: tcp_buffers}}
  end

  # ── TCP data ─────────────────────────────────────────────────────

  def handle_info({:tcp, tcp_socket, data}, state) do
    buffer = Map.get(state.tcp_buffers, tcp_socket, <<>>)
    buffer = buffer <> data
    {messages, remaining} = TCPFraming.parse(buffer)
    tcp_buffers = Map.put(state.tcp_buffers, tcp_socket, remaining)
    state = %{state | tcp_buffers: tcp_buffers}

    transport = {:tcp, tcp_socket}

    state =
      Enum.reduce(messages, state, fn message, state ->
        Logger.debug("TCP RX #{byte_size(message)}B")
        state = %{state | current_transport: transport}
        {actions, handler} = MessageHandler.handle_frame(state.handler, message)
        state = %{state | handler: handler}
        process_actions(actions, state)
      end)

    {:noreply, state}
  end

  # ── TCP connection closed ────────────────────────────────────────

  def handle_info({:tcp_closed, tcp_socket}, state) do
    Logger.info("TCP connection closed")
    tcp_buffers = Map.delete(state.tcp_buffers, tcp_socket)

    # Close sessions associated with this TCP connection
    tcp_transport = {:tcp, tcp_socket}
    {session_ids, session_transports} =
      Enum.reduce(state.session_transports, {[], %{}}, fn {sid, t}, {ids, kept} ->
        if t == tcp_transport do
          {[sid | ids], kept}
        else
          {ids, Map.put(kept, sid, t)}
        end
      end)

    handler =
      Enum.reduce(session_ids, state.handler, fn sid, handler ->
        {_actions, handler} = MessageHandler.close_session(handler, sid)
        handler
      end)

    {:noreply, %{state | tcp_buffers: tcp_buffers, session_transports: session_transports, handler: handler}}
  end

  def handle_info({:tcp_error, tcp_socket, reason}, state) do
    Logger.warning("TCP error: #{inspect(reason)}")
    # Treat as connection close
    handle_info({:tcp_closed, tcp_socket}, state)
  end

  # ── BLE messages (from Transport.BLE GenServer) ─────────────────

  def handle_info({:ble_connected, ble_pid}, state) do
    Logger.info("BLE connection from #{inspect(ble_pid)}")
    {:noreply, state}
  end

  def handle_info({:ble_data, ble_pid, data}, state) do
    transport = {:ble, ble_pid}
    Logger.debug("BLE RX #{byte_size(data)}B")
    state = %{state | current_transport: transport}
    {actions, handler} = MessageHandler.handle_frame(state.handler, data)
    state = %{state | handler: handler}
    state = process_actions(actions, state)
    {:noreply, state}
  end

  def handle_info({:ble_disconnected, ble_pid}, state) do
    Logger.info("BLE disconnected: #{inspect(ble_pid)}")
    ble_transport = {:ble, ble_pid}

    {session_ids, session_transports} =
      Enum.reduce(state.session_transports, {[], %{}}, fn {sid, t}, {ids, kept} ->
        if t == ble_transport do
          {[sid | ids], kept}
        else
          {ids, Map.put(kept, sid, t)}
        end
      end)

    handler =
      Enum.reduce(session_ids, state.handler, fn sid, handler ->
        {_actions, handler} = MessageHandler.close_session(handler, sid)
        handler
      end)

    {:noreply, %{state | session_transports: session_transports, handler: handler}}
  end

  # ── MRP timeout ──────────────────────────────────────────────────

  def handle_info({:mrp_timeout, session_id, exchange_id, attempt}, state) do
    {action, handler} = MessageHandler.handle_mrp_timeout(
      state.handler, session_id, exchange_id, attempt
    )

    state = %{state | handler: handler}

    state =
      case action do
        {:send, frame} ->
          transport = Map.get(state.session_transports, session_id, state.current_transport)
          send_frame(state, transport, frame)
          state

        nil ->
          state
      end

    {:noreply, state}
  end

  # ── Subscription check ──────────────────────────────────────────

  def handle_info(:check_subscriptions, state) do
    {actions, handler} = MessageHandler.check_subscriptions(state.handler)
    {handler, state} = maybe_update_case(handler, state)
    handler = maybe_update_group_keys(handler)
    state = %{state | handler: handler}
    state = process_subscription_actions(actions, state)
    Process.send_after(self(), :check_subscriptions, @sub_check_interval)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_udp.close(state.socket)
    if state.tcp_listener, do: :gen_tcp.close(state.tcp_listener)

    # Close all TCP connections
    for {tcp_socket, _buf} <- state.tcp_buffers do
      :gen_tcp.close(tcp_socket)
    end

    :ok
  end

  # ── Private: TCP listener ──────────────────────────────────────

  defp start_tcp_listener(port) do
    case :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:backlog, 8}]) do
      {:ok, listener} ->
        spawn_acceptor(listener, self())
        listener

      {:error, reason} ->
        Logger.warning("Failed to start TCP listener on port #{port}: #{inspect(reason)}")
        nil
    end
  end

  defp spawn_acceptor(listener, node_pid) do
    spawn_link(fn -> accept_loop(listener, node_pid) end)
  end

  defp accept_loop(listener, node_pid) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :gen_tcp.controlling_process(socket, node_pid)
        :inet.setopts(socket, [{:active, true}])
        send(node_pid, {:tcp_accepted, socket})
        accept_loop(listener, node_pid)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("TCP accept error: #{inspect(reason)}")
        :ok
    end
  end

  # ── Private: Action processing ──────────────────────────────────

  defp process_actions(actions, state) do
    Enum.reduce(actions, state, fn action, state ->
      case action do
        {:send, frame} ->
          send_frame(state, state.current_transport, frame)
          state

        {:schedule_mrp, session_id, exchange_id, attempt, timeout_ms} ->
          # Skip MRP for TCP sessions — TCP provides reliability
          case Map.get(state.session_transports, session_id) do
            {:tcp, _} ->
              state

            _ ->
              Process.send_after(
                self(),
                {:mrp_timeout, session_id, exchange_id, attempt},
                timeout_ms
              )
              state
          end

        {:session_established, session_id} ->
          Logger.info("Session #{session_id} established via #{transport_name(state.current_transport)}")
          session_transports = Map.put(state.session_transports, session_id, state.current_transport)
          %{state | session_transports: session_transports}

        {:session_closed, session_id} ->
          Logger.info("Session #{session_id} closed")
          session_transports = Map.delete(state.session_transports, session_id)
          %{state | session_transports: session_transports}

        {:error, reason} ->
          Logger.warning("Protocol error: #{inspect(reason)}")
          state
      end
    end)
  end

  # Subscription actions need transport lookup by session_id since there's
  # no "current" incoming transport. The {:schedule_mrp, session_id, ...}
  # actions tell us which session the preceding {:send, frame} belongs to.
  defp process_subscription_actions(actions, state) do
    {state, _last_sid} =
      Enum.reduce(actions, {state, nil}, fn action, {state, last_sid} ->
        case action do
          {:send, frame} ->
            transport = if last_sid, do: Map.get(state.session_transports, last_sid)
            transport = transport || state.current_transport
            send_frame(state, transport, frame)
            {state, last_sid}

          {:schedule_mrp, session_id, exchange_id, attempt, timeout_ms} ->
            case Map.get(state.session_transports, session_id) do
              {:tcp, _} ->
                {state, session_id}

              _ ->
                Process.send_after(
                  self(),
                  {:mrp_timeout, session_id, exchange_id, attempt},
                  timeout_ms
                )
                {state, session_id}
            end

          other ->
            {process_actions([other], state), last_sid}
        end
      end)

    state
  end

  # ── Private: Frame sending ──────────────────────────────────────

  defp send_frame(state, {:udp, {ip, port}}, frame) do
    Logger.debug("UDP TX #{byte_size(frame)}B to #{:inet.ntoa(ip)}:#{port}")
    :gen_udp.send(state.socket, ip, port, frame)
  end

  defp send_frame(_state, {:tcp, tcp_socket}, frame) do
    Logger.debug("TCP TX #{byte_size(frame)}B")
    :gen_tcp.send(tcp_socket, TCPFraming.frame(frame))
  end

  defp send_frame(_state, {:ble, ble_pid}, frame) do
    Logger.debug("BLE TX #{byte_size(frame)}B")
    MatterEx.Transport.BLE.send(ble_pid, frame)
  end

  defp send_frame(_state, nil, _frame) do
    Logger.warning("Dropping frame: no transport available")
    :ok
  end

  defp transport_name({:udp, _}), do: "UDP"
  defp transport_name({:tcp, _}), do: "TCP"
  defp transport_name({:ble, _}), do: "BLE"
  defp transport_name(nil), do: "unknown"

  # ── Private: Per-peer transport update ──────────────────────

  # Update the stored transport for a session when the peer's address changes
  # (e.g., NAT rebinding, port change). Ensures subscription reports and MRP
  # retransmits reach the peer at their current address.
  defp update_peer_transport(state, data, transport) do
    case Header.decode(data) do
      {:ok, header, _rest} when header.session_id > 0 ->
        case Map.get(state.session_transports, header.session_id) do
          ^transport ->
            state

          old when old != nil ->
            Logger.debug("Peer address updated for session #{header.session_id}")
            session_transports = Map.put(state.session_transports, header.session_id, transport)
            %{state | session_transports: session_transports}

          nil ->
            state
        end

      _ ->
        state
    end
  end

  # ── Private: Group key update ──────────────────────────────

  defp maybe_update_group_keys(handler) do
    device = handler.device

    if device do
      gkm_name = device.__process_name__(0, :group_key_management)

      if gkm_name && Process.whereis(gkm_name) do
        keys = GenServer.call(gkm_name, :get_group_keys)
        MessageHandler.update_group_keys(handler, keys)
      else
        handler
      end
    else
      handler
    end
  end

  # ── Private: CASE update ────────────────────────────────────────

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
      # ACL entry with Matter TLV context tags:
      # 1=Privilege, 2=AuthMode, 3=Subjects, 4=Targets, 254=FabricIndex
      admin_entry = %{
        1 => {:uint, 5},
        2 => {:uint, 2},
        3 => {:array, [{:uint, admin_subject}]},
        4 => nil,
        254 => {:uint, fabric_index}
      }

      GenServer.call(acl_name, {:write_attribute, :acl, [admin_entry]})
    end
  end

  defp transition_mdns(%State{mdns: nil}, _creds), do: :ok

  defp transition_mdns(%State{mdns: mdns, commissioning_instance: inst, port: port}, creds) do
    alias MatterEx.CASE.Messages, as: CASEMessages
    alias MatterEx.MDNS

    # Withdraw commissioning advertisement
    if inst, do: MDNS.withdraw(mdns, inst)

    # Compute compressed fabric ID from root cert
    root_pub = if creds[:root_cert], do: CASEMessages.extract_public_key(creds.root_cert)

    if root_pub && creds[:fabric_id] && creds[:node_id] do
      Logger.debug("mDNS transition: root_pub=#{byte_size(root_pub)}B #{Base.encode16(root_pub)} fabric_id=#{creds.fabric_id} node_id=#{creds.node_id}")
      cfid = MDNS.compressed_fabric_id(root_pub, creds.fabric_id)
      Logger.debug("mDNS transition: cfid=#{Base.encode16(cfid)}")

      service = MDNS.operational_service(
        port: port,
        compressed_fabric_id: cfid,
        node_id: creds.node_id
      )

      MDNS.advertise(mdns, service)
      Logger.info("mDNS: transitioned to operational (_matter._tcp)")
    else
      Logger.warning("mDNS transition skipped: root_pub=#{inspect(root_pub && byte_size(root_pub))} fabric_id=#{inspect(creds[:fabric_id])} node_id=#{inspect(creds[:node_id])}")
    end
  end
end
