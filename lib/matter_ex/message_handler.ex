defmodule MatterEx.MessageHandler do
  @moduledoc """
  Central message orchestration — the single entry point for processing
  raw binary frames from any transport (BLE, UDP).

  Pure functional module — caller threads state through. Two paths:

  1. **Plaintext (session_id=0)**: PASE commissioning handshake
  2. **Encrypted (session_id>0)**: IM messages over established sessions

  ## Example

      handler = MessageHandler.new(
        device: MyDevice,
        passcode: 20202021,
        salt: salt,
        iterations: 1000,
        local_session_id: 1
      )

      # Process incoming frame from transport
      {actions, handler} = MessageHandler.handle_frame(handler, raw_frame)

      # Caller executes actions
      for action <- actions do
        case action do
          {:send, frame} -> transport_send(frame)
          {:schedule_mrp, sid, eid, attempt, ms} -> schedule_timer(sid, eid, attempt, ms)
          {:session_established, sid} -> log_session(sid)
        end
      end
  """

  require Logger

  alias MatterEx.{CASE, ExchangeManager, PASE, SecureChannel, Session}
  alias MatterEx.IM
  alias MatterEx.IM.{Router, SubscriptionManager}
  alias MatterEx.Protocol.{Counter, MessageCodec, ProtocolID}
  alias MatterEx.Protocol.MessageCodec.{Header, ProtoHeader}

  @type action ::
    {:send, binary()}
    | {:schedule_mrp, non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
    | {:session_established, non_neg_integer()}
    | {:session_closed, non_neg_integer()}

  @type session_entry :: %{
    session: Session.t(),
    exchange_mgr: ExchangeManager.t(),
    subscription_mgr: SubscriptionManager.t(),
    exchange_to_sub: %{non_neg_integer() => non_neg_integer()}
  }

  @type group_key_entry :: %{
    group_id: non_neg_integer(),
    session_id: non_neg_integer(),
    encrypt_key: binary()
  }

  @type t :: %__MODULE__{
    device: module() | nil,
    pase: PASE.t() | nil,
    case_states: %{non_neg_integer() => CASE.t()},
    sessions: %{non_neg_integer() => session_entry()},
    group_keys: %{non_neg_integer() => group_key_entry()},
    plaintext_counter: Counter.t()
  }

  defstruct device: nil,
            pase: nil,
            case_states: %{},
            sessions: %{},
            group_keys: %{},
            plaintext_counter: Counter.new()

  @doc """
  Create a new MessageHandler.

  Required options:
  - `:passcode` — commissioning passcode (integer)
  - `:salt` — PBKDF2 salt (binary)
  - `:iterations` — PBKDF2 iterations (integer)
  - `:local_session_id` — session ID for PASE (integer)

  Optional:
  - `:device` — device module for IM routing
  - `:noc` — Node Operational Certificate (binary, for CASE)
  - `:private_key` — ECDSA private key (binary, for CASE)
  - `:ipk` — Identity Protection Key (binary, for CASE)
  - `:node_id` — node ID (integer, for CASE)
  - `:fabric_id` — fabric ID (integer, for CASE)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    pase = PASE.new_device(
      passcode: Keyword.fetch!(opts, :passcode),
      salt: Keyword.fetch!(opts, :salt),
      iterations: Keyword.fetch!(opts, :iterations),
      local_session_id: Keyword.fetch!(opts, :local_session_id)
    )

    case_states = maybe_init_case(opts)

    %__MODULE__{
      device: Keyword.get(opts, :device),
      pase: pase,
      case_states: case_states,
      plaintext_counter: Counter.new(0)
    }
  end

  @doc """
  Process an incoming raw binary frame.

  Peeks at the session_id in the message header to choose
  the plaintext (PASE) or encrypted (IM) path.

  Returns `{actions, updated_state}`.
  """
  @spec handle_frame(t(), binary()) :: {[action()], t()}
  def handle_frame(%__MODULE__{} = state, frame) when is_binary(frame) do
    case Header.decode(frame) do
      {:ok, header, _rest} ->
        cond do
          header.session_type == :group ->
            handle_group_message(state, header, frame)

          header.session_id == 0 ->
            handle_plaintext(state, frame)

          true ->
            handle_encrypted(state, header.session_id, frame)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode message header: #{inspect(reason)}")
        {[{:error, reason}], state}
    end
  end

  @doc """
  Handle an MRP retransmission timer for a session's exchange.

  Returns `{action_or_nil, updated_state}`.
  """
  @spec handle_mrp_timeout(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
    {action() | nil, t()}
  def handle_mrp_timeout(%__MODULE__{} = state, session_id, exchange_id, attempt) do
    case Map.get(state.sessions, session_id) do
      nil ->
        Logger.warning("MRP timeout for unknown session #{session_id}")
        {nil, state}

      %{session: session, exchange_mgr: mgr} = entry ->
        case ExchangeManager.handle_timeout(mgr, exchange_id, attempt) do
          {:retransmit, proto, mgr} ->
            Logger.debug("MRP retransmit session=#{session_id} exchange=#{exchange_id} attempt=#{attempt}")
            {frame, session} = SecureChannel.seal(session, proto)
            entry = %{entry | session: session, exchange_mgr: mgr}
            sessions = Map.put(state.sessions, session_id, entry)
            {{:send, frame}, %{state | sessions: sessions}}

          {:give_up, _exchange_id, mgr} ->
            Logger.warning("MRP gave up on session=#{session_id} exchange=#{exchange_id} after #{attempt + 1} attempts")
            exchange_to_sub = Map.get(entry, :exchange_to_sub, %{})

            {sub_mgr, exchange_to_sub} =
              case Map.pop(exchange_to_sub, exchange_id) do
                {nil, exchange_to_sub} ->
                  {entry.subscription_mgr, exchange_to_sub}

                {sub_id, exchange_to_sub} ->
                  Logger.info("Cleaning up subscription #{sub_id} after MRP give_up on exchange #{exchange_id}")
                  {SubscriptionManager.unsubscribe(entry.subscription_mgr, sub_id), exchange_to_sub}
              end

            entry = %{entry | exchange_mgr: mgr, subscription_mgr: sub_mgr, exchange_to_sub: exchange_to_sub}
            sessions = Map.put(state.sessions, session_id, entry)
            {nil, %{state | sessions: sessions}}

          {:already_acked, mgr} ->
            entry = %{entry | exchange_mgr: mgr}
            sessions = Map.put(state.sessions, session_id, entry)
            {nil, %{state | sessions: sessions}}
        end
    end
  end

  @doc """
  Update CASE state with new credentials (e.g. after commissioning).

  Accepts the same keyword options as `new/1` for CASE:
  `:noc`, `:private_key`, `:ipk`, `:node_id`, `:fabric_id`.
  """
  @spec update_case(t(), keyword()) :: t()
  def update_case(%__MODULE__{} = state, opts) do
    new_entries = maybe_init_case(opts)
    %{state | case_states: Map.merge(state.case_states, new_entries)}
  end

  @doc """
  Update group keys from GroupKeyManagement cluster.

  Accepts a list of `%{group_id, session_id, encrypt_key}` entries.
  Indexes by session_id for fast lookup on incoming group messages.
  """
  @spec update_group_keys(t(), [group_key_entry()]) :: t()
  def update_group_keys(%__MODULE__{} = state, entries) when is_list(entries) do
    group_keys = Map.new(entries, fn entry -> {entry.session_id, entry} end)
    %{state | group_keys: group_keys}
  end

  @doc """
  Close a session, removing it and all its subscriptions.

  Returns `{actions, updated_state}` where actions may include
  `{:session_closed, session_id}`.
  """
  @spec close_session(t(), non_neg_integer()) :: {[action()], t()}
  def close_session(%__MODULE__{} = state, session_id) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {[], state}

      entry ->
        sub_count = map_size(entry.subscription_mgr.subscriptions)

        if sub_count > 0 do
          Logger.info("Closing session #{session_id}: removing #{sub_count} subscription(s)")
        end

        sessions = Map.delete(state.sessions, session_id)
        {[{:session_closed, session_id}], %{state | sessions: sessions}}
    end
  end

  # ── Plaintext path (PASE / CASE) ──────────────────────────────────

  @case_opcodes [:case_sigma1, :case_sigma3, :case_sigma2_resume]

  defp handle_plaintext(state, frame) do
    case MessageCodec.decode(frame) do
      {:ok, message} ->
        opcode_name = ProtocolID.opcode_name(
          message.proto.protocol_id,
          message.proto.opcode
        )

        cond do
          opcode_name in @case_opcodes ->
            handle_case_message(state, message, opcode_name)

          opcode_name == :standalone_ack ->
            # Standalone ACKs on the plaintext path are protocol-level and need no handling
            {[], state}

          true ->
            handle_pase_message(state, message, opcode_name)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode plaintext frame: #{inspect(reason)}")
        {[{:error, reason}], state}
    end
  end

  defp handle_pase_message(state, message, opcode_name) do
    case PASE.handle(state.pase, opcode_name, message.proto.payload) do
      {:reply, resp_type, resp_payload, pase} ->
        frame = build_plaintext_frame(state, message, resp_type, resp_payload)
        {counter_val, counter} = Counter.next(state.plaintext_counter)
        _ = counter_val
        {[{:send, frame}], %{state | pase: pase, plaintext_counter: counter}}

      {:established, :status_report, sr_payload, session, pase} ->
        Logger.info("PASE session established: local=#{session.local_session_id} peer=#{session.peer_session_id}")
        frame = build_plaintext_frame(state, message, :status_report, sr_payload)
        {_counter_val, counter} = Counter.next(state.plaintext_counter)

        handler = build_im_handler(state.device, session)
        mgr = ExchangeManager.new(handler: handler)

        entry = %{session: session, exchange_mgr: mgr, subscription_mgr: SubscriptionManager.new(), exchange_to_sub: %{}}
        sessions = Map.put(state.sessions, session.local_session_id, entry)

        actions = [
          {:send, frame},
          {:session_established, session.local_session_id}
        ]

        {actions, %{state | pase: pase, sessions: sessions, plaintext_counter: counter}}

      {:error, reason} ->
        Logger.warning("PASE error: #{inspect(reason)}")
        {[{:error, reason}], state}
    end
  end

  # ── Plaintext path (CASE) ──────────────────────────────────────────

  defp handle_case_message(state, message, opcode_name) do
    if map_size(state.case_states) == 0 do
      Logger.warning("CASE message received but CASE not configured")
      {[{:error, :case_not_configured}], state}
    else
      try_case_fabrics(state, message, opcode_name, Map.to_list(state.case_states), nil, false)
    end
  end

  # Fallback: all fabrics failed with destination_mismatch — retry first fabric
  # with dest_id check skipped (needed for chip-tool interop where dest_id
  # computation doesn't match).
  defp try_case_fabrics(state, message, opcode_name, [], :destination_mismatch, false) do
    [{fabric_index, case_state} | _] = Map.to_list(state.case_states)
    Logger.debug("CASE: no fabric matched destination_id, retrying fabric #{fabric_index} with skip_dest_check")
    relaxed = %{case_state | skip_dest_check: true}
    try_case_fabrics(state, message, opcode_name, [{fabric_index, relaxed}], nil, true)
  end

  defp try_case_fabrics(state, _message, _opcode_name, [], last_error, _retry) do
    reason = last_error || :no_matching_fabric
    Logger.warning("CASE error: #{inspect(reason)}")
    {[{:error, reason}], state}
  end

  defp try_case_fabrics(state, message, opcode_name, [{fabric_index, case_state} | rest], _last_error, retry) do
    # Reset stuck CASE state when receiving a new Sigma1 (e.g., previous handshake timed out)
    case_state = if opcode_name == :case_sigma1 and case_state.state != :idle do
      Logger.debug("CASE: resetting stuck state #{case_state.state} for fabric #{fabric_index}")
      reset_one_case(case_state)
    else
      case_state
    end

    case CASE.handle(case_state, opcode_name, message.proto.payload) do
      {:reply, resp_type, resp_payload, updated_cs} ->
        frame = build_plaintext_frame(state, message, resp_type, resp_payload)
        {_counter_val, counter} = Counter.next(state.plaintext_counter)
        case_states = Map.put(state.case_states, fabric_index, updated_cs)
        {[{:send, frame}], %{state | case_states: case_states, plaintext_counter: counter}}

      {:established, :status_report, sr_payload, session, _updated_cs} ->
        Logger.info("CASE session established: local=#{session.local_session_id} peer=#{session.peer_session_id}")
        frame = build_plaintext_frame(state, message, :status_report, sr_payload)
        {_counter_val, counter} = Counter.next(state.plaintext_counter)

        handler = build_im_handler(state.device, session)
        mgr = ExchangeManager.new(handler: handler)

        entry = %{session: session, exchange_mgr: mgr, subscription_mgr: SubscriptionManager.new(), exchange_to_sub: %{}}
        sessions = Map.put(state.sessions, session.local_session_id, entry)

        # Reset this fabric's CASE state for next handshake
        case_states = Map.put(state.case_states, fabric_index, reset_one_case(case_state))

        actions = [
          {:send, frame},
          {:session_established, session.local_session_id}
        ]

        {actions, %{state | case_states: case_states, sessions: sessions, plaintext_counter: counter}}

      {:error, reason} ->
        # Try next fabric
        try_case_fabrics(state, message, opcode_name, rest, reason, retry)
    end
  end

  defp maybe_init_case(opts) do
    noc = Keyword.get(opts, :noc)
    icac = Keyword.get(opts, :icac)
    private_key = Keyword.get(opts, :private_key)
    ipk = Keyword.get(opts, :ipk)
    node_id = Keyword.get(opts, :node_id)
    fabric_id = Keyword.get(opts, :fabric_id)
    fabric_index = Keyword.get(opts, :fabric_index, 1)
    root_public_key = extract_root_public_key(Keyword.get(opts, :root_cert))

    if noc && private_key && ipk && node_id && fabric_id do
      # IPK from AddNOC is the epoch key — derive the actual IPK per Matter spec 4.16.2.1:
      # IPK = HKDF(salt=CompressedFabricId, ikm=epochKey, info="GroupKey v1.0", length=16)
      derived_ipk = if root_public_key do
        alias MatterEx.Crypto.KDF
        cfid = MatterEx.MDNS.compressed_fabric_id(root_public_key, fabric_id)
        KDF.hkdf(cfid, ipk, "GroupKey v1.0", 16)
      else
        ipk
      end

      Logger.debug("maybe_init_case: node_id=#{inspect(node_id)}(0x#{Integer.to_string(node_id, 16)}) fabric_id=#{inspect(fabric_id)}(0x#{Integer.to_string(fabric_id, 16)}) epoch_key=#{Base.encode16(ipk)}(#{byte_size(ipk)}B) derived_ipk=#{Base.encode16(derived_ipk)}(#{byte_size(derived_ipk)}B) root_pub=#{if root_public_key, do: "#{Base.encode16(root_public_key)}(#{byte_size(root_public_key)}B)", else: "nil"}")
      case_session_id = :rand.uniform(65534)

      cs = CASE.new_device(
        noc: noc,
        icac: icac,
        private_key: private_key,
        ipk: derived_ipk,
        root_public_key: root_public_key,
        node_id: node_id,
        fabric_id: fabric_id,
        fabric_index: fabric_index,
        local_session_id: case_session_id
      )

      %{fabric_index => cs}
    else
      %{}
    end
  end

  defp extract_root_public_key(nil), do: nil
  defp extract_root_public_key(root_cert) do
    alias MatterEx.CASE.Messages, as: CASEMessages
    CASEMessages.extract_public_key(root_cert)
  end

  defp reset_one_case(cs) do
    case_session_id = :rand.uniform(65534)

    CASE.new_device(
      noc: cs.noc,
      icac: cs.icac,
      private_key: cs.private_key,
      ipk: cs.ipk,
      root_public_key: cs.root_public_key,
      node_id: cs.node_id,
      fabric_id: cs.fabric_id,
      fabric_index: cs.fabric_index,
      local_session_id: case_session_id
    )
  end

  # ── Plaintext frame builder ──────────────────────────────────────

  defp build_plaintext_frame(state, incoming_message, resp_type, resp_payload) do
    {counter_val, _counter} = Counter.next(state.plaintext_counter)

    resp_opcode = ProtocolID.opcode(:secure_channel, resp_type)

    header = %Header{
      session_id: 0,
      message_counter: counter_val,
      source_node_id: incoming_message.header.dest_node_id,
      dest_node_id: incoming_message.header.source_node_id,
      privacy: false,
      session_type: :unicast
    }

    proto = %ProtoHeader{
      initiator: false,
      needs_ack: true,
      ack_counter: incoming_message.header.message_counter,
      opcode: resp_opcode,
      exchange_id: incoming_message.proto.exchange_id,
      protocol_id: 0x0000,
      payload: resp_payload
    }

    IO.iodata_to_binary(MessageCodec.encode(header, proto))
  end

  # ── Group message path ────────────────────────────────────────────

  defp handle_group_message(state, header, frame) do
    case Map.get(state.group_keys, header.session_id) do
      nil ->
        Logger.warning("Group message for unknown group session #{header.session_id}")
        {[{:error, :unknown_group_session}], state}

      %{encrypt_key: key, group_id: group_id} ->
        source_node_id = header.source_node_id || 0
        nonce = MessageCodec.build_nonce(header.security_flags, header.message_counter, source_node_id)

        case MessageCodec.decode_encrypted(frame, key, nonce) do
          {:ok, message} ->
            Logger.debug("Group message from node #{source_node_id} for group #{group_id}")
            handle_group_im(state, message, source_node_id, group_id)

          {:error, reason} ->
            Logger.warning("Failed to decrypt group message: #{inspect(reason)}")
            {[{:error, reason}], state}
        end
    end
  end

  defp handle_group_im(state, message, source_node_id, group_id) do
    if state.device do
      opcode = ProtocolID.opcode_name(message.proto.protocol_id, message.proto.opcode)

      context = %{
        auth_mode: :group,
        subject: source_node_id,
        fabric_index: 0,
        group_id: group_id
      }

      case IM.decode(opcode, message.proto.payload) do
        {:ok, request} ->
          # Process but discard response (no-reply semantics for group messages)
          _response = Router.handle(state.device, opcode, request, context)
          {[], state}

        {:error, _reason} ->
          {[], state}
      end
    else
      {[], state}
    end
  end

  # ── Encrypted path (IM) ───────────────────────────────────────────

  defp handle_encrypted(state, session_id, frame) do
    case Map.get(state.sessions, session_id) do
      nil ->
        Logger.warning("Received frame for unknown session #{session_id}")
        {[{:error, :unknown_session}], state}

      %{session: session, exchange_mgr: mgr, subscription_mgr: sub_mgr} = entry ->
        case SecureChannel.open(session, frame) do
          {:ok, message, session} ->
            opcode = ProtocolID.opcode_name(message.proto.protocol_id, message.proto.opcode)
            Logger.debug("Decrypted message: protocol=#{inspect(message.proto.protocol_id)} opcode=#{inspect(message.proto.opcode)} (#{inspect(opcode)}) payload=#{byte_size(message.proto.payload)}B exchange=#{message.proto.exchange_id}")

            # Pre-process subscribe_request: register subscription, build priming report, inject temp handler
            {mgr, sub_mgr} = maybe_setup_subscription(mgr, sub_mgr, opcode, message.proto, state.device, session)

            {em_actions, mgr} = ExchangeManager.handle_message(
              mgr, message.proto, message.header.message_counter
            )

            # Restore the original handler after subscribe processing
            mgr = if opcode == :subscribe_request do
              %{mgr | handler: build_im_handler(state.device, session)}
            else
              mgr
            end

            {actions, session} = process_exchange_actions(em_actions, session, session_id)
            entry = %{entry | session: session, exchange_mgr: mgr, subscription_mgr: sub_mgr}
            sessions = Map.put(state.sessions, session_id, entry)
            {actions, %{state | sessions: sessions}}

          {:error, reason} ->
            Logger.warning("Failed to decrypt frame for session #{session_id}: #{inspect(reason)}")
            {[{:error, reason}], state}
        end
    end
  end

  defp process_exchange_actions(em_actions, session, session_id) do
    Enum.flat_map_reduce(em_actions, session, fn action, session ->
      case action do
        {:reply, proto} ->
          {frame, session} = SecureChannel.seal(session, proto)
          {[{:send, frame}], session}

        {:schedule_mrp, exchange_id, attempt, timeout_ms} ->
          {[{:schedule_mrp, session_id, exchange_id, attempt, timeout_ms}], session}

        {:ack, proto} ->
          {frame, session} = SecureChannel.seal(session, proto)
          {[{:send, frame}], session}

        {:error, _reason} = err ->
          {[err], session}
      end
    end)
  end

  # ── Private helpers ────────────────────────────────────────────────

  defp maybe_setup_subscription(mgr, sub_mgr, :subscribe_request, proto, device, session) do
    case IM.decode(:subscribe_request, proto.payload) do
      {:ok, %IM.SubscribeRequest{} = req} ->
        {sub_id, sub_mgr} = SubscriptionManager.subscribe(
          sub_mgr,
          req.attribute_paths,
          req.min_interval,
          req.max_interval
        )

        # Build priming ReportData with initial attribute values
        context = session_context(session)
        priming_report = if device do
          report = Router.handle_read(device, %IM.ReadRequest{attribute_paths: req.attribute_paths}, context)
          %IM.ReportData{
            subscription_id: sub_id,
            attribute_reports: report.attribute_reports,
            event_reports: report.event_reports,
            suppress_response: false
          }
        else
          %IM.ReportData{subscription_id: sub_id, suppress_response: false}
        end

        # Inject temporary handler that returns the priming ReportData
        temp_handler = fn _opcode, _request -> priming_report end

        # Store the encoded SubscribeResponse for phase 2 (sent after client ACKs priming report)
        sub_response = %IM.SubscribeResponse{subscription_id: sub_id, max_interval: req.max_interval}
        encoded_sub_response = IM.encode(sub_response)
        pending = Map.put(mgr.pending_subscribe_responses, proto.exchange_id, encoded_sub_response)

        {%{mgr | handler: temp_handler, pending_subscribe_responses: pending}, sub_mgr}

      _ ->
        {mgr, sub_mgr}
    end
  end

  defp maybe_setup_subscription(mgr, sub_mgr, _opcode, _proto, _device, _session), do: {mgr, sub_mgr}

  @doc """
  Check all sessions for subscriptions that are due for periodic reports.

  For each due subscription, reads current attribute values, compares with
  last reported values, and sends a ReportData if changed.

  Returns `{actions, updated_state}`.
  """
  @spec check_subscriptions(t()) :: {[action()], t()}
  def check_subscriptions(%__MODULE__{} = state) do
    now = System.monotonic_time(:second)

    Enum.flat_map_reduce(state.sessions, state, fn {session_id, entry}, state ->
      due = SubscriptionManager.due_reports(entry.subscription_mgr, now)

      Enum.flat_map_reduce(due, state, fn {sub_id, paths}, state ->
        entry = state.sessions[session_id]
        sub = SubscriptionManager.get(entry.subscription_mgr, sub_id)

        case build_subscription_report(state.device, sub_id, paths, entry.session) do
          nil ->
            # No device, skip
            sub_mgr = SubscriptionManager.record_report(entry.subscription_mgr, sub_id, %{}, now)
            entry = %{entry | subscription_mgr: sub_mgr}
            sessions = Map.put(state.sessions, session_id, entry)
            {[], %{state | sessions: sessions}}

          {report_data, current_values} ->
            # Check if values changed and min_interval allows sending
            cond do
              current_values == sub.last_values ->
                # No change — just update timer
                sub_mgr = SubscriptionManager.record_report(entry.subscription_mgr, sub_id, current_values, now)
                entry = %{entry | subscription_mgr: sub_mgr}
                sessions = Map.put(state.sessions, session_id, entry)
                {[], %{state | sessions: sessions}}

              SubscriptionManager.throttled?(entry.subscription_mgr, sub_id, now) ->
                # Values changed but min_interval not elapsed — suppress
                Logger.debug("Subscription #{sub_id}: suppressed report (min_interval throttle)")
                sub_mgr = SubscriptionManager.record_report(entry.subscription_mgr, sub_id, sub.last_values, now)
                entry = %{entry | subscription_mgr: sub_mgr}
                sessions = Map.put(state.sessions, session_id, entry)
                {[], %{state | sessions: sessions}}

              true ->
                # Values changed and min_interval allows — send report
                payload = IM.encode(report_data)
                im_protocol_id = ProtocolID.protocol_id(:interaction_model)

                {proto, mrp_actions, mgr} = ExchangeManager.initiate(
                  entry.exchange_mgr,
                  im_protocol_id,
                  :report_data,
                  payload
                )

                {frame, session} = SecureChannel.seal(entry.session, proto)

                # Track exchange→subscription mapping for give_up cleanup
                exchange_to_sub = Map.get(entry, :exchange_to_sub, %{})
                exchange_to_sub = Map.put(exchange_to_sub, proto.exchange_id, sub_id)

                sub_mgr = SubscriptionManager.record_sent(entry.subscription_mgr, sub_id, current_values, now)
                entry = %{entry | session: session, exchange_mgr: mgr, subscription_mgr: sub_mgr, exchange_to_sub: exchange_to_sub}
                sessions = Map.put(state.sessions, session_id, entry)

                send_actions = [{:send, frame}]
                schedule_actions = Enum.map(mrp_actions, fn {:schedule_mrp, eid, attempt, timeout} ->
                  {:schedule_mrp, session_id, eid, attempt, timeout}
                end)

                {send_actions ++ schedule_actions, %{state | sessions: sessions}}
            end
        end
      end)
    end)
  end

  defp build_subscription_report(nil, _sub_id, _paths, _session), do: nil

  defp build_subscription_report(device, sub_id, paths, session) do
    context = session_context(session)
    report = Router.handle_read(device, %IM.ReadRequest{attribute_paths: paths}, context)

    current_values =
      Enum.reduce(report.attribute_reports, %{}, fn
        {:data, data}, acc ->
          key = {data.path[:endpoint], data.path[:cluster], data.path[:attribute]}
          Map.put(acc, key, data.value)
        _, acc ->
          acc
      end)

    report_data = %IM.ReportData{
      subscription_id: sub_id,
      attribute_reports: report.attribute_reports,
      suppress_response: true
    }

    {report_data, current_values}
  end

  defp build_im_handler(nil, _session), do: fn _opcode, _request -> nil end

  defp build_im_handler(device, session) do
    context = session_context(session)
    fn opcode, request -> Router.handle(device, opcode, request, context) end
  end

  defp session_context(session) do
    %{
      auth_mode: session.auth_mode || :pase,
      subject: session.peer_node_id || 0,
      fabric_index: session.fabric_index || 0,
      attestation_challenge: session.attestation_challenge
    }
  end
end
