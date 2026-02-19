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

  alias Matterlix.{ExchangeManager, PASE, SecureChannel, Session}
  alias Matterlix.IM.Router, as: IMRouter
  alias Matterlix.Protocol.{Counter, MessageCodec, ProtocolID}
  alias Matterlix.Protocol.MessageCodec.{Header, ProtoHeader}

  @type action ::
    {:send, binary()}
    | {:schedule_mrp, non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
    | {:session_established, non_neg_integer()}

  @type session_entry :: %{
    session: Session.t(),
    exchange_mgr: ExchangeManager.t()
  }

  @type t :: %__MODULE__{
    device: module() | nil,
    pase: PASE.t() | nil,
    sessions: %{non_neg_integer() => session_entry()},
    plaintext_counter: Counter.t()
  }

  defstruct device: nil,
            pase: nil,
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
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    pase = PASE.new_device(
      passcode: Keyword.fetch!(opts, :passcode),
      salt: Keyword.fetch!(opts, :salt),
      iterations: Keyword.fetch!(opts, :iterations),
      local_session_id: Keyword.fetch!(opts, :local_session_id)
    )

    %__MODULE__{
      device: Keyword.get(opts, :device),
      pase: pase,
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

  # ── Plaintext path (PASE) ─────────────────────────────────────────

  defp handle_plaintext(state, frame) do
    case MessageCodec.decode(frame) do
      {:ok, message} ->
        opcode_name = ProtocolID.opcode_name(
          message.proto.protocol_id,
          message.proto.opcode
        )

        handle_pase_message(state, message, opcode_name)

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

        entry = %{session: session, exchange_mgr: mgr}
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

      %{session: session, exchange_mgr: mgr} = entry ->
        case SecureChannel.open(session, frame) do
          {:ok, message, session} ->
            {em_actions, mgr} = ExchangeManager.handle_message(
              mgr, message.proto, message.header.message_counter
            )

            {actions, session} = process_exchange_actions(em_actions, session, session_id)
            entry = %{entry | session: session, exchange_mgr: mgr}
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

  defp build_im_handler(nil), do: fn _opcode, _request -> nil end

  defp build_im_handler(device) do
    fn opcode, request -> IMRouter.handle(device, opcode, request) end
  end
end
