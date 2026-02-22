defmodule Matterlix.ExchangeManager do
  @moduledoc """
  Exchange correlation, protocol dispatch, ACK management, and MRP integration.

  Pure functional module — caller threads state through. Bridges the gap
  between SecureChannel (encrypt/decrypt) and protocol handlers (IM, PASE).

  ## Device usage

      handler = fn(opcode, request) -> IM.Router.handle(device, opcode, request) end
      mgr = ExchangeManager.new(handler: handler)

      # Incoming frame already decrypted by SecureChannel.open
      {actions, mgr} = ExchangeManager.handle_message(mgr, proto_header, message_counter)

      # Caller executes actions: {:reply, proto}, {:schedule_mrp, ...}, {:ack, ...}
  """

  alias Matterlix.IM
  alias Matterlix.Protocol.{MRP, ProtocolID}
  alias Matterlix.Protocol.MessageCodec.ProtoHeader

  @type action ::
    {:reply, ProtoHeader.t()}
    | {:schedule_mrp, non_neg_integer(), non_neg_integer(), non_neg_integer()}
    | {:ack, non_neg_integer()}

  require Logger

  @type exchange :: %{
    role: :initiator | :responder,
    protocol: atom()
  }

  @type t :: %__MODULE__{
    handler: (atom(), struct() -> struct()) | nil,
    exchanges: %{non_neg_integer() => exchange()},
    mrp: MRP.t(),
    next_exchange_id: non_neg_integer(),
    pending_acks: [non_neg_integer()],
    timed_exchanges: %{non_neg_integer() => integer()}
  }

  defstruct handler: nil,
            exchanges: %{},
            mrp: MRP.new(),
            next_exchange_id: 1,
            pending_acks: [],
            timed_exchanges: %{},
            pending_subscribe_responses: %{},
            pending_chunks: %{}

  @doc """
  Create a new ExchangeManager.

  Options:
  - `:handler` — `fn(opcode_atom, request_struct) -> response_struct`.
    Called for IM request dispatch.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      handler: Keyword.get(opts, :handler),
      mrp: MRP.new()
    }
  end

  @doc """
  Process an incoming decrypted message.

  Takes the ProtoHeader from `SecureChannel.open` and the message_counter
  from the message header (needed for ACK piggybacking).

  Returns `{actions, updated_state}` where actions is a list of:
  - `{:reply, proto}` — send this ProtoHeader (caller seals with SecureChannel)
  - `{:schedule_mrp, exchange_id, attempt, timeout_ms}` — schedule retransmit timer
  - `{:ack, message_counter}` — send standalone ACK for this counter
  """
  @spec handle_message(t(), ProtoHeader.t(), non_neg_integer()) :: {[action()], t()}
  def handle_message(%__MODULE__{} = state, %ProtoHeader{} = proto, message_counter) do
    protocol = ProtocolID.protocol_name(proto.protocol_id)
    opcode = ProtocolID.opcode_name(proto.protocol_id, proto.opcode)

    case {protocol, opcode} do
      {:secure_channel, :standalone_ack} ->
        handle_standalone_ack(state, proto)

      {:interaction_model, im_opcode} ->
        handle_im_message(state, proto, im_opcode, message_counter)

      other ->
        Logger.debug("Unsupported protocol/opcode: #{inspect(other)}")
        {[{:error, :unsupported_protocol}], state}
    end
  end

  @doc """
  Handle an MRP retransmission timer firing.

  Returns:
  - `{:retransmit, proto, state}` — resend this ProtoHeader
  - `{:give_up, exchange_id, state}` — max retransmissions reached
  - `{:already_acked, state}` — exchange was already acknowledged
  """
  @spec handle_timeout(t(), non_neg_integer(), non_neg_integer()) ::
    {:retransmit, ProtoHeader.t(), t()}
    | {:give_up, non_neg_integer(), t()}
    | {:already_acked, t()}
  def handle_timeout(%__MODULE__{} = state, exchange_id, attempt) do
    case MRP.on_timeout(state.mrp, exchange_id, attempt) do
      {:retransmit, proto_binary, mrp} ->
        proto = :erlang.binary_to_term(proto_binary)
        {:retransmit, proto, %{state | mrp: mrp}}

      {:give_up, mrp} ->
        exchanges = Map.delete(state.exchanges, exchange_id)
        {:give_up, exchange_id, %{state | mrp: mrp, exchanges: exchanges}}

      {:already_acked, mrp} ->
        {:already_acked, %{state | mrp: mrp}}
    end
  end

  @doc """
  Initiate an outgoing exchange (initiator side).

  Assigns the next exchange_id, builds a ProtoHeader with `initiator: true`,
  and records it in MRP if `reliable: true` (default).

  Returns `{proto, actions, updated_state}`.
  """
  @spec initiate(t(), non_neg_integer(), atom(), binary(), keyword()) ::
    {ProtoHeader.t(), [action()], t()}
  def initiate(%__MODULE__{} = state, protocol_id, opcode_name, payload, opts \\ []) do
    exchange_id = state.next_exchange_id
    reliable = Keyword.get(opts, :reliable, true)

    opcode_num = ProtocolID.opcode(
      ProtocolID.protocol_name(protocol_id),
      opcode_name
    )

    proto = %ProtoHeader{
      initiator: true,
      needs_ack: reliable,
      opcode: opcode_num,
      exchange_id: exchange_id,
      protocol_id: protocol_id,
      payload: payload
    }

    protocol = ProtocolID.protocol_name(protocol_id)
    exchanges = Map.put(state.exchanges, exchange_id, %{
      role: :initiator,
      protocol: protocol
    })

    state = %{state |
      exchanges: exchanges,
      next_exchange_id: exchange_id + 1
    }

    {state, actions} =
      if reliable do
        mrp = MRP.record_send(state.mrp, exchange_id, :erlang.term_to_binary(proto))
        timeout = MRP.backoff_ms(state.mrp, 0)
        {%{state | mrp: mrp}, [{:schedule_mrp, exchange_id, 0, timeout}]}
      else
        {state, []}
      end

    {proto, actions, state}
  end

  # ── Private: IM handling ──────────────────────────────────────────

  defp handle_im_message(state, proto, opcode, message_counter) do
    # Handle piggybacked ACK if present (clears MRP retransmit for our previous message)
    state = if proto.ack_counter do
      case MRP.on_ack(state.mrp, proto.exchange_id) do
        {:ok, mrp} -> %{state | mrp: mrp}
        {:error, :not_found} -> state
      end
    else
      state
    end

    # Handle piggybacked status_response for pending chunked reports or subscribe completion
    cond do
      opcode == :status_response and Map.get(state.pending_chunks, proto.exchange_id) == :done ->
        # Final StatusResponse after last chunk — ACK and close
        state = ack_and_clear_mrp(state, proto)
        state = %{state | pending_chunks: Map.delete(state.pending_chunks, proto.exchange_id)}
        state = close_exchange(state, proto.exchange_id)
        actions = if proto.needs_ack, do: [{:ack, build_standalone_ack(proto, message_counter)}], else: []
        {actions, state}

      opcode == :status_response and Map.has_key?(state.pending_chunks, proto.exchange_id) ->
        send_next_chunk(state, proto, message_counter)

      opcode == :status_response and Map.has_key?(state.pending_subscribe_responses, proto.exchange_id) ->
        complete_subscribe(state, proto, Map.fetch!(state.pending_subscribe_responses, proto.exchange_id), message_counter)

      true ->
        # Register exchange
        exchanges = Map.put(state.exchanges, proto.exchange_id, %{
          role: :responder,
          protocol: :interaction_model
        })
        state = %{state | exchanges: exchanges}

        handle_im_message_normal(state, proto, opcode, message_counter)
    end
  end

  defp handle_im_message_normal(state, proto, opcode, message_counter) do
    case IM.decode(opcode, proto.payload) do
      {:ok, request} ->
        suppress? = Map.get(request, :suppress_response, false)

        case response_opcode(opcode) do
          {:ok, _resp_opcode_name} when suppress? ->
            # suppress_response set — execute handler but skip IM response, just ACK
            Logger.debug("suppress_response: executing #{inspect(opcode)} without IM reply")
            state.handler.(opcode, request)
            state = close_exchange(state, proto.exchange_id)
            actions = if proto.needs_ack, do: [{:ack, build_standalone_ack(proto, message_counter)}], else: []
            {actions, state}

          {:ok, resp_opcode_name} ->
            dispatch_and_reply(state, proto, opcode, request, resp_opcode_name, message_counter)

          :no_response ->
            # No response expected, just ACK if needed
            state = close_exchange(state, proto.exchange_id)
            actions = if proto.needs_ack, do: [{:ack, build_standalone_ack(proto, message_counter)}], else: []
            {actions, state}
        end

      {:error, reason} ->
        Logger.debug("IM.decode failed for opcode #{inspect(opcode)}: #{inspect(reason)}, payload: #{Base.encode16(proto.payload)}")
        state = close_exchange(state, proto.exchange_id)
        actions = if proto.needs_ack, do: [{:ack, build_standalone_ack(proto, message_counter)}], else: []
        {[{:error, :decode_failed} | actions], state}
    end
  end

  # Max IM payload size for UDP (leaving room for message header + encryption overhead)
  @max_im_payload 1150

  defp dispatch_and_reply(state, proto, opcode, request, resp_opcode_name, message_counter) do
    response = state.handler.(opcode, request)

    # Chunk ReportData if it exceeds the UDP payload limit
    case maybe_chunk_report(response, resp_opcode_name) do
      [first_chunk | remaining] when remaining != [] ->
        dispatch_chunked(state, proto, opcode, request, resp_opcode_name, message_counter, first_chunk, remaining)

      _ ->
        dispatch_single(state, proto, opcode, request, resp_opcode_name, message_counter, response)
    end
  end

  defp maybe_chunk_report(%IM.ReportData{} = report, :report_data) do
    payload = IM.encode(report)
    if byte_size(payload) > @max_im_payload do
      IM.chunk_report_data(report, 4)
    else
      [report]
    end
  end

  defp maybe_chunk_report(response, _opcode), do: [response]

  defp dispatch_single(state, proto, opcode, request, resp_opcode_name, message_counter, response) do
    response_payload = IM.encode(response)

    Logger.debug("IM response #{inspect(resp_opcode_name)}: #{inspect(response)}")
    Logger.debug("IM response TLV (#{byte_size(response_payload)}B): #{Base.encode16(response_payload)}")

    resp_opcode_num = ProtocolID.opcode(:interaction_model, resp_opcode_name)

    reply_proto = %ProtoHeader{
      initiator: false,
      needs_ack: true,
      ack_counter: if(proto.needs_ack, do: message_counter, else: nil),
      opcode: resp_opcode_num,
      exchange_id: proto.exchange_id,
      protocol_id: proto.protocol_id,
      payload: response_payload
    }

    # Record in MRP for reliability
    mrp = MRP.record_send(state.mrp, proto.exchange_id, :erlang.term_to_binary(reply_proto))
    timeout = MRP.backoff_ms(state.mrp, 0, deterministic: true)
    state = %{state | mrp: mrp}

    # For timed requests / subscribe, keep exchange open
    state =
      cond do
        opcode == :timed_request ->
          deadline = System.monotonic_time(:millisecond) + request.timeout_ms
          %{state | timed_exchanges: Map.put(state.timed_exchanges, proto.exchange_id, deadline)}

        opcode == :subscribe_request ->
          # Keep exchange open — SubscribeResponse will be sent after client ACKs priming ReportData
          state

        true ->
          close_exchange(state, proto.exchange_id)
      end

    {[{:reply, reply_proto}, {:schedule_mrp, proto.exchange_id, 0, timeout}], state}
  end

  defp dispatch_chunked(state, proto, _opcode, _request, resp_opcode_name, message_counter, first_chunk, remaining) do
    response_payload = IM.encode(first_chunk)

    Logger.debug("IM chunked response (chunk 1/#{1 + length(remaining)}): #{byte_size(response_payload)}B")

    resp_opcode_num = ProtocolID.opcode(:interaction_model, resp_opcode_name)

    reply_proto = %ProtoHeader{
      initiator: false,
      needs_ack: true,
      ack_counter: if(proto.needs_ack, do: message_counter, else: nil),
      opcode: resp_opcode_num,
      exchange_id: proto.exchange_id,
      protocol_id: proto.protocol_id,
      payload: response_payload
    }

    mrp = MRP.record_send(state.mrp, proto.exchange_id, :erlang.term_to_binary(reply_proto))
    timeout = MRP.backoff_ms(state.mrp, 0, deterministic: true)
    state = %{state | mrp: mrp}

    # Store remaining chunks — exchange stays open until all chunks are sent
    state = %{state | pending_chunks: Map.put(state.pending_chunks, proto.exchange_id, remaining)}

    {[{:reply, reply_proto}, {:schedule_mrp, proto.exchange_id, 0, timeout}], state}
  end

  defp send_next_chunk(state, proto, message_counter) do
    state = if proto.ack_counter do
      case MRP.on_ack(state.mrp, proto.exchange_id) do
        {:ok, mrp} -> %{state | mrp: mrp}
        {:error, :not_found} -> state
      end
    else
      state
    end

    [next_chunk | remaining] = Map.fetch!(state.pending_chunks, proto.exchange_id)
    chunk_num = if remaining == [], do: "last", else: "#{length(remaining)} remaining"
    response_payload = IM.encode(next_chunk)

    Logger.debug("IM chunked response (#{chunk_num}): #{byte_size(response_payload)}B")

    resp_opcode_num = ProtocolID.opcode(:interaction_model, :report_data)

    reply_proto = %ProtoHeader{
      initiator: false,
      needs_ack: true,
      ack_counter: if(proto.needs_ack, do: message_counter, else: nil),
      opcode: resp_opcode_num,
      exchange_id: proto.exchange_id,
      protocol_id: proto.protocol_id,
      payload: response_payload
    }

    mrp = MRP.record_send(state.mrp, proto.exchange_id, :erlang.term_to_binary(reply_proto))
    timeout = MRP.backoff_ms(state.mrp, 0, deterministic: true)
    state = %{state | mrp: mrp}

    # When remaining is empty, keep a :done marker so the final StatusResponse
    # from the client gets properly ACKed before closing the exchange
    state = if remaining == [] do
      %{state | pending_chunks: Map.put(state.pending_chunks, proto.exchange_id, :done)}
    else
      %{state | pending_chunks: Map.put(state.pending_chunks, proto.exchange_id, remaining)}
    end

    {[{:reply, reply_proto}, {:schedule_mrp, proto.exchange_id, 0, timeout}], state}
  end

  # ── Private: Subscribe completion (phase 2) ────────────────────────

  defp complete_subscribe(state, proto, sub_payload, message_counter) do
    Logger.debug("IM subscribe: sending SubscribeResponse (completing subscribe on exchange #{proto.exchange_id})")

    resp_opcode_num = ProtocolID.opcode(:interaction_model, :subscribe_response)

    reply_proto = %ProtoHeader{
      initiator: false,
      needs_ack: true,
      ack_counter: if(proto.needs_ack, do: message_counter, else: nil),
      opcode: resp_opcode_num,
      exchange_id: proto.exchange_id,
      protocol_id: ProtocolID.protocol_id(:interaction_model),
      payload: sub_payload
    }

    mrp = MRP.record_send(state.mrp, proto.exchange_id, :erlang.term_to_binary(reply_proto))
    timeout = MRP.backoff_ms(state.mrp, 0, deterministic: true)

    state = %{state |
      mrp: mrp,
      pending_subscribe_responses: Map.delete(state.pending_subscribe_responses, proto.exchange_id)
    }
    state = close_exchange(state, proto.exchange_id)

    {[{:reply, reply_proto}, {:schedule_mrp, proto.exchange_id, 0, timeout}], state}
  end

  # ── Private: Standalone ACK ───────────────────────────────────────

  defp handle_standalone_ack(state, proto) do
    case MRP.on_ack(state.mrp, proto.exchange_id) do
      {:ok, mrp} ->
        exchanges = Map.delete(state.exchanges, proto.exchange_id)
        {[], %{state | mrp: mrp, exchanges: exchanges}}

      {:error, :not_found} ->
        {[], state}
    end
  end

  defp ack_and_clear_mrp(state, proto) do
    if proto.ack_counter do
      case MRP.on_ack(state.mrp, proto.exchange_id) do
        {:ok, mrp} -> %{state | mrp: mrp}
        {:error, :not_found} -> state
      end
    else
      state
    end
  end

  # ── Private: Exchange lifecycle ───────────────────────────────────

  defp close_exchange(state, exchange_id) do
    %{state |
      exchanges: Map.delete(state.exchanges, exchange_id),
      timed_exchanges: Map.delete(state.timed_exchanges, exchange_id)
    }
  end

  # ── Private: Standalone ACK builder ─────────────────────────────────

  defp build_standalone_ack(incoming_proto, ack_counter) do
    %ProtoHeader{
      initiator: !incoming_proto.initiator,
      needs_ack: false,
      ack_counter: ack_counter,
      opcode: ProtocolID.opcode(:secure_channel, :standalone_ack),
      exchange_id: incoming_proto.exchange_id,
      protocol_id: ProtocolID.protocol_id(:secure_channel),
      payload: <<>>
    }
  end

  # ── Private: Opcode mapping ──────────────────────────────────────

  defp response_opcode(:read_request), do: {:ok, :report_data}
  defp response_opcode(:write_request), do: {:ok, :write_response}
  defp response_opcode(:invoke_request), do: {:ok, :invoke_response}
  defp response_opcode(:subscribe_request), do: {:ok, :report_data}
  defp response_opcode(:timed_request), do: {:ok, :status_response}
  defp response_opcode(_), do: :no_response
end
