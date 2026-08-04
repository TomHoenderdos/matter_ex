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

  # Fallback poll interval. Reporting is push-driven; this only backstops the
  # max-interval report and min_interval-throttled flushes, so it can be slow.
  @sub_check_interval 10_000

  # Cap on how many queued attribute-change messages one notification drains.
  @max_drained_changes 32

  # Re-registering on the reporting registry has to wait for its supervisor to
  # restart it: at :DOWN time the name never resolves yet (measured: nil on every
  # trial, name back after ~2ms). Retry rather than give up on the first miss.
  @reporting_retry_ms 50
  @reporting_retry_limit 20

  # Re-announcement backoff while no controller is connected. RFC 6762 §6 forbids
  # multicasting the same record more than once a second, and §8.3 wants
  # announcement intervals to at least double; a fixed 1 Hz would sit exactly on
  # that limit forever. 1s → 2s → 4s … capped at half the record TTL.
  @reannounce_base_ms 1_000
  @reannounce_max_ms 60_000
  @sol_socket 1
  @so_bindtodevice 25

  defmodule State do
    @moduledoc false
    defstruct [
      :handler,
      :socket,
      :socket6,
      :port,
      :tcp_sup,
      :mdns,
      :commissioning_service,
      :commissioning_instance,
      :operational_instance,
      # Periodic subscription poll interval (ms); the push path is primary
      # Set from @sub_check_interval in init/1; nil only if constructed directly.
      sub_check_interval: nil,
      # Current transport for the frame being processed
      current_transport: nil,
      # Per-session transport: session_id => {:udp, {ip, port}} | {:tcp, tcp_socket}
      session_transports: %{},
      # TCP per-connection buffers: tcp_socket => binary
      tcp_buffers: %{},
      # Backoff schedule for re-announcing mDNS while no controller is connected
      reannounce_in: nil,
      reannounce_at: nil
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
  - `:sub_check_interval` — fallback poll interval in ms (default 10_000). The
    push path reports changes immediately; this is the fallback for keep-alives
    and `min_interval`-throttled changes.
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
    device = Keyword.fetch!(opts, :device)
    sub_check_interval = Keyword.get(opts, :sub_check_interval, @sub_check_interval)

    # Start commissioning agent if not already running
    if !Process.whereis(Commissioning) do
      Commissioning.start_link()
    end

    # Subscribe to the device's reporting bus for push-based reporting. Best
    # effort: the poll still runs if the device has no reporting registry.
    if subscribe_to_reporting(device) == :unavailable do
      Process.send_after(self(), {:resubscribe_reporting, 1}, @reporting_retry_ms)
    end

    case open_udp_sockets(udp_port) do
      {:ok, socket, socket6, assigned_port} ->
        # Start the TCP acceptor in its own supervised crash domain, on the
        # same port UDP was assigned. An accept error restarts only the
        # acceptor; a TCP-listen failure is non-fatal (node stays UDP-only).
        tcp_sup = if tcp_enabled, do: start_tcp_acceptor(assigned_port)

        # Generate random session ID for PASE (1..65534)
        local_session_id = :rand.uniform(65534)

        handler =
          MessageHandler.new(
            device: device,
            passcode: Keyword.fetch!(opts, :passcode),
            salt: Keyword.fetch!(opts, :salt),
            iterations: Keyword.fetch!(opts, :iterations),
            local_session_id: local_session_id
          )

        Logger.info("Matter node listening on UDP port #{assigned_port}")
        Process.send_after(self(), :check_subscriptions, sub_check_interval)

        {:ok,
         %State{
           handler: handler,
           socket: socket,
           socket6: socket6,
           port: assigned_port,
           tcp_sup: tcp_sup,
           sub_check_interval: sub_check_interval,
           mdns: Keyword.get(opts, :mdns),
           commissioning_service: Keyword.get(opts, :commissioning_service),
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
    state = refresh_runtime_state(state)
    {:noreply, state}
  end

  # ── TCP connection acceptance ────────────────────────────────────

  def handle_info({:tcp_accepted, tcp_socket}, state) do
    # The acceptor handed us a passive socket; as the new owner we enable
    # active mode so data arrives as {:tcp, socket, data} messages.
    :inet.setopts(tcp_socket, [{:active, true}])

    # A peer that connects and resets immediately is already gone by the time we
    # get here, so peername/1 returns an error. Matching {:ok, _} on it would
    # raise and take the node down — UDP and every session with it — which is
    # exactly the failure this change exists to prevent, one process further up.
    case :inet.peername(tcp_socket) do
      {:ok, {ip, port}} ->
        Logger.info("TCP connection accepted from #{:inet.ntoa(ip)}:#{port}")
        {:noreply, %{state | tcp_buffers: Map.put(state.tcp_buffers, tcp_socket, <<>>)}}

      {:error, reason} ->
        Logger.debug("TCP peer gone before it could be registered: #{inspect(reason)}")
        :gen_tcp.close(tcp_socket)
        {:noreply, state}
    end
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
        state = process_actions(actions, state)
        refresh_runtime_state(state)
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

    {:noreply,
     %{state | tcp_buffers: tcp_buffers, session_transports: session_transports, handler: handler}}
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
    state = refresh_runtime_state(state)
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
    {actions, handler} =
      MessageHandler.handle_mrp_timeout(
        state.handler,
        session_id,
        exchange_id,
        attempt
      )

    state = %{state | handler: handler}

    state =
      case actions do
        actions when is_list(actions) ->
          state = process_actions(actions, state)
          refresh_runtime_state(state)

        nil ->
          state
      end

    {:noreply, state}
  end

  # ── Push-based reporting ────────────────────────────────────────

  # Retry registering on the device's reporting bus.
  #
  # Only reachable for a node started before its device supervisor: once
  # registered we are *linked* to the registry partition (see
  # subscribe_to_reporting/2), so registry death takes this node with it and our
  # own supervisor restarts us — init/1 registers again. There is no surviving-
  # the-registry case to handle here.
  def handle_info({:resubscribe_reporting, attempt}, state) do
    case subscribe_to_reporting(state.handler.device, quiet: true) do
      :ok ->
        Logger.info("Registered for reporting after #{attempt} attempt(s)")
        {:noreply, state}

      :unavailable when attempt >= @reporting_retry_limit ->
        Logger.warning(
          "Reporting registry still unavailable after " <>
            "#{@reporting_retry_limit * @reporting_retry_ms}ms; reports will fall back to " <>
            "polling every #{state.sub_check_interval}ms"
        )

        {:noreply, state}

      :unavailable ->
        Process.send_after(self(), {:resubscribe_reporting, attempt + 1}, @reporting_retry_ms)
        {:noreply, state}
    end
  end

  # A cluster attribute changed. Report the affected subscriptions immediately
  # rather than waiting for the next poll. Coalesce a same-tick burst (e.g. a
  # command that touches several clusters) into one pass.
  def handle_info({:attribute_changed, endpoint, cluster}, state) do
    targets = drain_attribute_changes([{endpoint, cluster}])
    {actions, handler} = MessageHandler.report_targets(state.handler, targets)
    state = %{state | handler: handler}
    state = process_subscription_actions(actions, state)
    {:noreply, state}
  end

  # ── Subscription check ──────────────────────────────────────────

  def handle_info(:check_subscriptions, state) do
    {actions, handler} = MessageHandler.check_subscriptions(state.handler)
    {handler, state} = maybe_update_case(handler, state)
    handler = maybe_update_group_keys(handler)
    state = %{state | handler: handler}
    state = process_subscription_actions(actions, state)
    state = maybe_reannounce_while_disconnected(state)
    Process.send_after(self(), :check_subscriptions, state.sub_check_interval)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # While no controller holds a session, keep re-announcing operational mDNS so a
  # controller re-resolves the device after a new DHCP address or a missed
  # announcement burst. Stops the moment a session exists, so it costs nothing in
  # steady state. Rides the always-on subscription tick rather than adding a timer.
  defp maybe_reannounce_while_disconnected(%{mdns: nil} = state), do: state

  defp maybe_reannounce_while_disconnected(state) do
    if map_size(state.handler.sessions) > 0 do
      # A controller is here; nothing to advertise for. Reset so the next
      # disconnect starts a fresh burst rather than resuming at the slow rate.
      %{state | reannounce_in: nil, reannounce_at: nil}
    else
      reannounce_with_backoff(state)
    end
  end

  defp reannounce_with_backoff(state) do
    now = System.monotonic_time(:millisecond)
    interval = state.reannounce_in || @reannounce_base_ms

    if now >= (state.reannounce_at || now) do
      MatterEx.MDNS.reannounce_all(state.mdns)

      %{
        state
        | reannounce_at: now + interval,
          reannounce_in: min(interval * 2, @reannounce_max_ms)
      }
    else
      state
    end
  end

  defp refresh_runtime_state(state) do
    {handler, state} = maybe_update_case(state.handler, state)
    handler = maybe_update_group_keys(handler)
    %{state | handler: handler}
  end

  # Register on the device's reporting bus, and watch it so registration survives
  # a restart of the device supervisor.
  #
  # Falling back to the poll is correct when a device has no reporting registry,
  # but it must not be silent: the only symptom is "reports got slower", and since
  # the fallback interval is #{@sub_check_interval}ms that is slower than the poll
  # this replaced. Two ways it bites — a node started before its device
  # supervisor, and a :one_for_one restart of that supervisor leaving the registry
  # empty while the node keeps running.
  # Register on the device's reporting bus.
  #
  # `Registry.register/3` **links** the caller to the registry partition, so this
  # node dies with the registry and is restarted by its own supervisor, which
  # registers again through init/1. That is the recovery path — a monitor would
  # never get to run, because the exit signal arrives first.
  #
  # The case worth handling is a node started *before* its device supervisor:
  # nothing to register with, no link, and reports silently fall back to polling
  # at an interval slower than the poll this replaced. So it warns and retries.
  defp subscribe_to_reporting(device, opts \\ []) do
    Registry.register(:"#{device}.Reporting", :changes, nil)
    :ok
  rescue
    ArgumentError ->
      unless opts[:quiet] do
        Logger.warning(
          "#{inspect(:"#{device}.Reporting")} is not running — subscription reports will fall " <>
            "back to polling every #{@sub_check_interval}ms until it starts. Start the device " <>
            "supervisor before the node."
        )
      end

      :unavailable
  end

  # Pull other queued attribute-changed messages so a burst reports once.
  #
  # Bounded: this is a selective receive with no ref, so each drained message
  # rescans the mailbox from the front. Unbounded that is O(n·m) under UDP load,
  # and it keeps jumping ahead of queued packets. Anything past the cap is picked
  # up on the next notification or the fallback poll.
  defp drain_attribute_changes(acc), do: drain_attribute_changes(acc, @max_drained_changes)

  defp drain_attribute_changes(acc, 0), do: Enum.uniq(acc)

  defp drain_attribute_changes(acc, remaining) do
    receive do
      {:attribute_changed, endpoint, cluster} ->
        drain_attribute_changes([{endpoint, cluster} | acc], remaining - 1)
    after
      0 -> Enum.uniq(acc)
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_udp.close(state.socket)
    if state.socket6, do: :gen_udp.close(state.socket6)
    # The TCP acceptor (and its listen socket) is torn down via its supervisor,
    # which is linked to this process.

    # Close all TCP connections
    for {tcp_socket, _buf} <- state.tcp_buffers do
      :gen_tcp.close(tcp_socket)
    end

    :ok
  end

  # ── Private: TCP listener ──────────────────────────────────────

  defp open_udp_sockets(port) do
    with {:ok, socket} <- :gen_udp.open(port, [:binary, {:active, true}, :inet]),
         {:ok, assigned_port} <- :inet.port(socket) do
      socket6_opts =
        [
          :binary,
          {:active, true},
          :inet6,
          {:ipv6_v6only, true}
        ] ++ bind_to_device_opts(preferred_ipv6_device())

      case :gen_udp.open(assigned_port, socket6_opts) do
        {:ok, socket6} ->
          {:ok, socket, socket6, assigned_port}

        {:error, reason} ->
          Logger.warning("Failed to open IPv6 UDP port #{assigned_port}: #{inspect(reason)}")
          {:ok, socket, nil, assigned_port}
      end
    end
  end

  defp preferred_ipv6_device do
    if File.exists?("/sys/class/net/wlan0/ifindex"), do: "wlan0"
  end

  defp bind_to_device_opts(nil), do: []

  defp bind_to_device_opts(device) do
    [{:raw, @sol_socket, @so_bindtodevice, device <> <<0>>}]
  end

  # Start the TCP acceptor under its own supervisor so an accept crash restarts
  # only the acceptor, not this node. The supervisor is linked to this process,
  # so it is torn down when the node stops. Returns the supervisor pid, or nil
  # when TCP is disabled.
  defp start_tcp_acceptor(port) do
    {:ok, sup} =
      Supervisor.start_link(
        [{MatterEx.Node.TCPAcceptor, port: port, node: self()}],
        strategy: :one_for_one,
        max_restarts: 10,
        max_seconds: 5
      )

    sup
  end

  # ── Private: Action processing ──────────────────────────────────

  defp process_actions(actions, state) do
    Enum.reduce(actions, state, fn action, state ->
      case action do
        {:send, frame} ->
          send_frame(state, state.current_transport, frame)
          state

        {:send, session_id, frame} ->
          transport = Map.get(state.session_transports, session_id, state.current_transport)
          send_frame(state, transport, frame)
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
          Logger.info(
            "Session #{session_id} established via #{transport_name(state.current_transport)}"
          )

          session_transports =
            Map.put(state.session_transports, session_id, state.current_transport)

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
  # no "current" incoming transport.
  defp process_subscription_actions(actions, state) do
    {state, _last_sid} =
      Enum.reduce(actions, {state, nil}, fn action, {state, last_sid} ->
        case action do
          {:send, session_id, frame} ->
            transport = Map.get(state.session_transports, session_id)
            send_frame(state, transport, frame)
            {state, session_id}

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

    case udp_socket_for_ip(state, ip) do
      nil ->
        Logger.warning("Dropping UDP frame: no socket for #{inspect(ip)}")
        :ok

      socket ->
        :gen_udp.send(socket, ip, port, frame)
    end
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

  defp udp_socket_for_ip(state, ip) when tuple_size(ip) == 4, do: state.socket
  defp udp_socket_for_ip(state, ip) when tuple_size(ip) == 8, do: state.socket6

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
        {handler, maybe_transition_to_commissioning(state)}

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

          state = transition_mdns(state, creds)

          {handler, state}
        else
          {handler, state}
        end
    end
  end

  defp maybe_transition_to_commissioning(
         %State{
           mdns: mdns,
           commissioning_service: service,
           operational_instance: operational_instance
         } = state
       )
       when mdns != nil and service != nil and operational_instance != nil do
    if Commissioning.commissioned?() do
      state
    else
      MatterEx.DebugTrace.record(%{
        type: :mdns_return_to_commissioning,
        operational_instance: operational_instance,
        commissioning_instance: service[:instance]
      })

      MatterEx.MDNS.withdraw(mdns, operational_instance)
      MatterEx.MDNS.advertise(mdns, service)

      %{
        state
        | commissioning_instance: service[:instance],
          operational_instance: nil
      }
    end
  end

  defp maybe_transition_to_commissioning(state), do: state

  defp write_initial_acl(device, admin_subject, fabric_index) do
    acl_name = device.__process_name__(0, :access_control)

    if acl_name && Process.whereis(acl_name) do
      existing_entries =
        case GenServer.call(acl_name, {:read_attribute, :acl}) do
          {:ok, entries} when is_list(entries) -> entries
          _ -> []
        end

      # ACL entry with Matter TLV context tags:
      # 1=Privilege, 2=AuthMode, 3=Subjects, 4=Targets, 254=FabricIndex
      admin_entry = %{
        1 => {:uint, 5},
        2 => {:uint, 2},
        3 => {:array, [{:uint, admin_subject}]},
        4 => nil,
        254 => {:uint, fabric_index}
      }

      entries =
        existing_entries
        |> Enum.reject(&(acl_fabric_index(&1) == fabric_index))
        |> Kernel.++([admin_entry])

      GenServer.call(acl_name, {:write_attribute, :acl, entries})
    end
  end

  defp acl_fabric_index(%{fabric_index: fabric_index}), do: fabric_index
  defp acl_fabric_index(%{254 => {:uint, fabric_index}}), do: fabric_index
  defp acl_fabric_index(%{254 => fabric_index}) when is_integer(fabric_index), do: fabric_index
  defp acl_fabric_index(_), do: nil

  defp transition_mdns(%State{mdns: nil} = state, _creds), do: state

  defp transition_mdns(
         %State{mdns: mdns, commissioning_instance: inst, port: port} = state,
         creds
       ) do
    alias MatterEx.CASE.Messages, as: CASEMessages
    alias MatterEx.MDNS

    # Withdraw commissioning advertisement
    if inst do
      MatterEx.DebugTrace.record(%{type: :mdns_withdraw_commissioning, instance: inst})
      MDNS.withdraw(mdns, inst)
    end

    # Compute compressed fabric ID from root cert
    root_pub = if creds[:root_cert], do: CASEMessages.extract_public_key(creds.root_cert)

    if root_pub && creds[:fabric_id] && creds[:node_id] do
      Logger.debug(
        "mDNS transition: root_pub=#{byte_size(root_pub)}B #{Base.encode16(root_pub)} fabric_id=#{creds.fabric_id} node_id=#{creds.node_id}"
      )

      cfid = MDNS.compressed_fabric_id(root_pub, creds.fabric_id)
      Logger.debug("mDNS transition: cfid=#{Base.encode16(cfid)}")

      service =
        MDNS.operational_service(
          port: port,
          compressed_fabric_id: cfid,
          node_id: creds.node_id
        )

      MatterEx.DebugTrace.record(%{
        type: :mdns_advertise_operational,
        instance: service[:instance],
        service: service[:service],
        subtypes: service[:subtypes],
        txt: service[:txt],
        port: port,
        compressed_fabric_id: Base.encode16(cfid),
        fabric_id: creds.fabric_id,
        node_id: creds.node_id
      })

      MDNS.advertise(mdns, service)
      Logger.info("mDNS: transitioned to operational (_matter._tcp)")
      %{state | commissioning_instance: nil, operational_instance: service[:instance]}
    else
      MatterEx.DebugTrace.record(%{
        type: :mdns_transition_skipped,
        root_pub_size: root_pub && byte_size(root_pub),
        fabric_id: creds[:fabric_id],
        node_id: creds[:node_id]
      })

      Logger.warning(
        "mDNS transition skipped: root_pub=#{inspect(root_pub && byte_size(root_pub))} fabric_id=#{inspect(creds[:fabric_id])} node_id=#{inspect(creds[:node_id])}"
      )

      state
    end
  end
end
