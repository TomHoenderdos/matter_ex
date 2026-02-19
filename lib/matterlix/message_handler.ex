defmodule Matterlix.MessageHandler do
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

  alias Matterlix.{CASE, ExchangeManager, PASE, SecureChannel, Session}
  alias Matterlix.IM
  alias Matterlix.IM.{Router, SubscriptionManager}
  alias Matterlix.Protocol.{Counter, MessageCodec, ProtocolID}
  alias Matterlix.Protocol.MessageCodec.{Header, ProtoHeader}

  @type action ::
    {:send, binary()}
    | {:schedule_mrp, non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
    | {:session_established, non_neg_integer()}

  @type session_entry :: %{
    session: Session.t(),
    exchange_mgr: ExchangeManager.t(),
    subscription_mgr: SubscriptionManager.t()
  }

  @type t :: %__MODULE__{
    device: module() | nil,
    pase: PASE.t() | nil,
    case_state: CASE.t() | nil,
    sessions: %{non_neg_integer() => session_entry()},
    plaintext_counter: Counter.t()
  }

  defstruct device: nil,
            pase: nil,
            case_state: nil,
            sessions: %{},
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

    case_state = maybe_init_case(opts)

    %__MODULE__{
      device: Keyword.get(opts, :device),
      pase: pase,
      case_state: case_state,
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
        if header.session_id == 0 do
          handle_plaintext(state, frame)
        else
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
            entry = %{entry | exchange_mgr: mgr}
            sessions = Map.put(state.sessions, session_id, entry)
            {nil, %{state | sessions: sessions}}

          {:already_acked, mgr} ->
            entry = %{entry | exchange_mgr: mgr}
            sessions = Map.put(state.sessions, session_id, entry)
            {nil, %{state | sessions: sessions}}
        end
    end
  end

  # ── Plaintext path (PASE / CASE) ──────────────────────────────────

  @case_opcodes [:case_sigma1, :case_sigma3]

  defp handle_plaintext(state, frame) do
    case MessageCodec.decode(frame) do
      {:ok, message} ->
        opcode_name = ProtocolID.opcode_name(
          message.proto.protocol_id,
          message.proto.opcode
        )

        if opcode_name in @case_opcodes do
          handle_case_message(state, message, opcode_name)
        else
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

        handler = build_im_handler(state.device)
        mgr = ExchangeManager.new(handler: handler)

        entry = %{session: session, exchange_mgr: mgr, subscription_mgr: SubscriptionManager.new()}
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
    case state.case_state do
      nil ->
        Logger.warning("CASE message received but CASE not configured")
        {[{:error, :case_not_configured}], state}

      case_state ->
        case CASE.handle(case_state, opcode_name, message.proto.payload) do
          {:reply, resp_type, resp_payload, case_state} ->
            frame = build_plaintext_frame(state, message, resp_type, resp_payload)
            {_counter_val, counter} = Counter.next(state.plaintext_counter)
            {[{:send, frame}], %{state | case_state: case_state, plaintext_counter: counter}}

          {:established, :status_report, sr_payload, session, _case_state} ->
            Logger.info("CASE session established: local=#{session.local_session_id} peer=#{session.peer_session_id}")
            frame = build_plaintext_frame(state, message, :status_report, sr_payload)
            {_counter_val, counter} = Counter.next(state.plaintext_counter)

            handler = build_im_handler(state.device)
            mgr = ExchangeManager.new(handler: handler)

            entry = %{session: session, exchange_mgr: mgr, subscription_mgr: SubscriptionManager.new()}
            sessions = Map.put(state.sessions, session.local_session_id, entry)

            # Reset CASE state for next handshake
            new_case = reset_case(state.case_state)

            actions = [
              {:send, frame},
              {:session_established, session.local_session_id}
            ]

            {actions, %{state | case_state: new_case, sessions: sessions, plaintext_counter: counter}}

          {:error, reason} ->
            Logger.warning("CASE error: #{inspect(reason)}")
            {[{:error, reason}], state}
        end
    end
  end

  defp maybe_init_case(opts) do
    noc = Keyword.get(opts, :noc)
    private_key = Keyword.get(opts, :private_key)
    ipk = Keyword.get(opts, :ipk)
    node_id = Keyword.get(opts, :node_id)
    fabric_id = Keyword.get(opts, :fabric_id)

    if noc && private_key && ipk && node_id && fabric_id do
      # Generate a random CASE session ID different from PASE
      case_session_id = :rand.uniform(65534)

      CASE.new_device(
        noc: noc,
        private_key: private_key,
        ipk: ipk,
        node_id: node_id,
        fabric_id: fabric_id,
        local_session_id: case_session_id
      )
    end
  end

  defp reset_case(nil), do: nil

  defp reset_case(cs) do
    case_session_id = :rand.uniform(65534)

    CASE.new_device(
      noc: cs.noc,
      icac: cs.icac,
      private_key: cs.private_key,
      ipk: cs.ipk,
      node_id: cs.node_id,
      fabric_id: cs.fabric_id,
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
      privacy: false,
      session_type: :unicast
    }

    proto = %ProtoHeader{
      initiator: false,
      opcode: resp_opcode,
      exchange_id: incoming_message.proto.exchange_id,
      protocol_id: 0x0000,
      payload: resp_payload
    }

    IO.iodata_to_binary(MessageCodec.encode(header, proto))
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

            # Pre-process subscribe_request: register subscription and inject temp handler
            {mgr, sub_mgr} = maybe_setup_subscription(mgr, sub_mgr, opcode, message.proto)

            {em_actions, mgr} = ExchangeManager.handle_message(
              mgr, message.proto, message.header.message_counter
            )

            # Restore the original handler after subscribe processing
            mgr = if opcode == :subscribe_request do
              %{mgr | handler: build_im_handler(state.device)}
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

        {:ack, _counter} ->
          # Standalone ACK — build and send
          # For now, we don't send standalone ACKs (responses piggyback them)
          {[], session}

        {:error, _reason} = err ->
          {[err], session}
      end
    end)
  end

  # ── Private helpers ────────────────────────────────────────────────

  defp maybe_setup_subscription(mgr, sub_mgr, :subscribe_request, proto) do
    case IM.decode(:subscribe_request, proto.payload) do
      {:ok, %IM.SubscribeRequest{} = req} ->
        {sub_id, sub_mgr} = SubscriptionManager.subscribe(
          sub_mgr,
          req.attribute_paths,
          req.min_interval,
          req.max_interval
        )

        # Inject temporary handler that returns SubscribeResponse with correct sub_id
        temp_handler = fn _opcode, _request ->
          %IM.SubscribeResponse{
            subscription_id: sub_id,
            max_interval: req.max_interval
          }
        end

        {%{mgr | handler: temp_handler}, sub_mgr}

      _ ->
        {mgr, sub_mgr}
    end
  end

  defp maybe_setup_subscription(mgr, sub_mgr, _opcode, _proto), do: {mgr, sub_mgr}

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

        case build_subscription_report(state.device, sub_id, paths) do
          nil ->
            # No device, skip
            sub_mgr = SubscriptionManager.record_report(entry.subscription_mgr, sub_id, %{}, now)
            entry = %{entry | subscription_mgr: sub_mgr}
            sessions = Map.put(state.sessions, session_id, entry)
            {[], %{state | sessions: sessions}}

          {report_data, current_values} ->
            # Check if values changed
            if current_values == sub.last_values do
              # No change — just update timer
              sub_mgr = SubscriptionManager.record_report(entry.subscription_mgr, sub_id, current_values, now)
              entry = %{entry | subscription_mgr: sub_mgr}
              sessions = Map.put(state.sessions, session_id, entry)
              {[], %{state | sessions: sessions}}
            else
              # Values changed — send report
              payload = IM.encode(report_data)
              im_protocol_id = ProtocolID.protocol_id(:interaction_model)

              {proto, mrp_actions, mgr} = ExchangeManager.initiate(
                entry.exchange_mgr,
                im_protocol_id,
                :report_data,
                payload
              )

              {frame, session} = SecureChannel.seal(entry.session, proto)

              sub_mgr = SubscriptionManager.record_report(entry.subscription_mgr, sub_id, current_values, now)
              entry = %{entry | session: session, exchange_mgr: mgr, subscription_mgr: sub_mgr}
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

  defp build_subscription_report(nil, _sub_id, _paths), do: nil

  defp build_subscription_report(device, sub_id, paths) do
    report = Router.handle_read(device, %IM.ReadRequest{attribute_paths: paths})

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

  defp build_im_handler(nil), do: fn _opcode, _request -> nil end

  defp build_im_handler(device) do
    fn opcode, request -> Router.handle(device, opcode, request) end
  end
end
