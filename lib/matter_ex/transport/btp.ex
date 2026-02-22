defmodule MatterEx.Transport.BTP do
  @moduledoc """
  BLE Transport Protocol — fragmentation, reassembly, and handshake.

  BTP sits between raw BLE characteristic writes/indications and the Matter
  message layer. It handles:

  - Fragmenting a message into MTU-sized BTP packets
  - Reassembling incoming fragments into a complete message
  - Handshake encode/decode for MTU and window size negotiation
  - Ack packet generation

  State is a plain struct threaded through function calls — no GenServer at
  this layer.

  ## Example

      state = BTP.new(mtu: 64)
      {packets, state} = BTP.fragment(state, some_large_binary)
      # packets is a list of binaries ready to send over BLE

      # On the receiving side:
      state = BTP.new(mtu: 64)
      {:ok, state} = BTP.receive_segment(state, packet_1)
      {:complete, message, state} = BTP.receive_segment(state, packet_2)
  """

  import Bitwise
  alias MatterEx.Transport.BTP.Packet

  @default_mtu 247
  @default_window_size 6

  @flag_e 0x08
  @flag_b 0x10

  defstruct mtu: @default_mtu,
            window_size: @default_window_size,
            tx_seq: 0,
            rx_seq: nil,
            rx_buffer: [],
            rx_message_length: nil,
            ack_pending: false

  @type t :: %__MODULE__{
          mtu: pos_integer(),
          window_size: pos_integer(),
          tx_seq: 0..255,
          rx_seq: 0..255 | nil,
          rx_buffer: [binary()],
          rx_message_length: non_neg_integer() | nil,
          ack_pending: boolean()
        }

  @doc """
  Create a new BTP state.

  Options:
  - `:mtu` — negotiated MTU (default 247)
  - `:window_size` — max unacked segments (default 6)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      mtu: Keyword.get(opts, :mtu, @default_mtu),
      window_size: Keyword.get(opts, :window_size, @default_window_size)
    }
  end

  @doc """
  Fragment a message into BTP packets.

  Returns `{packets, new_state}` where `packets` is a list of binaries.
  The first packet has the B (beginning) flag and includes the total message
  length. The last packet has the E (ending) flag. Each packet gets an
  incrementing sequence number (wrapping at 255).
  """
  @spec fragment(t(), binary()) :: {[binary()], t()}
  def fragment(%__MODULE__{mtu: mtu, tx_seq: tx_seq} = state, message)
      when is_binary(message) do
    # First fragment: flags(1) + seq(1) + msg_len(2) + payload = mtu
    # So payload space = mtu - 4
    # Subsequent: flags(1) + seq(1) + payload = mtu
    # So payload space = mtu - 2
    first_payload_max = max(mtu - 4, 0)
    rest_payload_max = max(mtu - 2, 0)
    total_len = byte_size(message)

    # Split the message
    first_size = min(first_payload_max, total_len)
    <<first_chunk::binary-size(first_size), remaining::binary>> = message
    rest_chunks = chunk_binary(remaining, rest_payload_max)

    all_chunks = [first_chunk | rest_chunks]
    last_index = length(all_chunks) - 1

    {packets, final_seq} =
      all_chunks
      |> Enum.with_index()
      |> Enum.map_reduce(tx_seq, fn {chunk, i}, seq ->
        is_first = i == 0
        is_last = i == last_index

        flags =
          (if is_first, do: @flag_b, else: 0) |||
            (if is_last, do: @flag_e, else: 0)

        packet =
          IO.iodata_to_binary(
            Packet.encode_data(%{
              flags: flags,
              ack: nil,
              seq: seq,
              msg_len: if(is_first, do: total_len, else: nil),
              payload: chunk
            })
          )

        {packet, rem(seq + 1, 256)}
      end)

    {packets, %{state | tx_seq: final_seq}}
  end

  @doc """
  Process one incoming BTP segment.

  Returns:
  - `{:ok, new_state}` — fragment buffered, message not yet complete
  - `{:complete, message, new_state}` — full message reassembled
  - `{:ack_only, ack_num, new_state}` — received an ack-only packet
  - `{:error, reason}` — sequence error or invalid packet
  """
  @spec receive_segment(t(), binary()) ::
          {:ok, t()}
          | {:complete, binary(), t()}
          | {:ack_only, non_neg_integer(), t()}
          | {:error, atom()}
  def receive_segment(%__MODULE__{} = state, segment) when is_binary(segment) do
    case Packet.decode(segment) do
      {:ack_only, ack_num} ->
        {:ack_only, ack_num, state}

      {:data, %{beginning: true} = pkt} ->
        handle_beginning(state, pkt)

      {:data, %{beginning: false} = pkt} ->
        handle_continuation(state, pkt)

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :unexpected_packet_type}
    end
  end

  @doc """
  Encode a BTP handshake request.

  Options:
  - `:versions` — 4-byte supported versions binary (default `<<0, 0, 4, 0>>`, version 4)
  - `:mtu` — proposed MTU (default 247)
  - `:window_size` — proposed window size (default 6)
  """
  @spec handshake_request(keyword()) :: binary()
  def handshake_request(opts \\ []) do
    versions = Keyword.get(opts, :versions, <<0, 0, 4, 0>>)
    mtu = Keyword.get(opts, :mtu, @default_mtu)
    window_size = Keyword.get(opts, :window_size, @default_window_size)

    IO.iodata_to_binary(Packet.encode_handshake_request(versions, mtu, window_size))
  end

  @doc """
  Encode a BTP handshake response.

  - `selected_version` — chosen BTP version (integer)

  Options:
  - `:mtu` — selected MTU (default 247)
  - `:window_size` — selected window size (default 6)
  """
  @spec handshake_response(non_neg_integer(), keyword()) :: binary()
  def handshake_response(selected_version, opts \\ []) do
    mtu = Keyword.get(opts, :mtu, @default_mtu)
    window_size = Keyword.get(opts, :window_size, @default_window_size)

    IO.iodata_to_binary(
      Packet.encode_handshake_response(selected_version, mtu, window_size)
    )
  end

  @doc """
  Decode a handshake packet.

  Returns `{:request, params}` or `{:response, params}` or `{:error, reason}`.
  """
  @spec decode_handshake(binary()) ::
          {:request, map()} | {:response, map()} | {:error, atom()}
  def decode_handshake(binary) when is_binary(binary) do
    case Packet.decode(binary) do
      {:handshake_request, params} -> {:request, params}
      {:handshake_response, params} -> {:response, params}
      _ -> {:error, :not_a_handshake}
    end
  end

  @doc """
  Encode an ack-only packet.
  """
  @spec encode_ack(non_neg_integer()) :: binary()
  def encode_ack(ack_num) when ack_num in 0..255 do
    IO.iodata_to_binary(Packet.encode_ack(ack_num))
  end

  ## Private

  defp handle_beginning(state, %{seq: seq, msg_len: msg_len, payload: payload, ending: ending?}) do
    # Beginning segment: start fresh reassembly
    new_state = %{state |
      rx_buffer: [payload],
      rx_message_length: msg_len,
      rx_seq: rem(seq + 1, 256),
      ack_pending: true
    }

    if ending? do
      finish_reassembly(new_state)
    else
      {:ok, new_state}
    end
  end

  defp handle_continuation(%{rx_seq: nil}, _pkt) do
    {:error, :unexpected_continuation}
  end

  defp handle_continuation(%{rx_seq: expected} = _state, %{seq: seq})
       when seq != expected do
    {:error, :sequence_gap}
  end

  defp handle_continuation(state, %{seq: seq, payload: payload, ending: ending?}) do
    new_state = %{state |
      rx_buffer: [payload | state.rx_buffer],
      rx_seq: rem(seq + 1, 256),
      ack_pending: true
    }

    if ending? do
      finish_reassembly(new_state)
    else
      {:ok, new_state}
    end
  end

  defp finish_reassembly(state) do
    message = state.rx_buffer |> Enum.reverse() |> IO.iodata_to_binary()

    if state.rx_message_length != nil and byte_size(message) != state.rx_message_length do
      {:error, :length_mismatch}
    else
      {:complete, message, %{state | rx_buffer: [], rx_message_length: nil}}
    end
  end

  defp chunk_binary(<<>>, _size), do: []

  defp chunk_binary(binary, size) when byte_size(binary) <= size do
    [binary]
  end

  defp chunk_binary(binary, size) do
    <<chunk::binary-size(size), rest::binary>> = binary
    [chunk | chunk_binary(rest, size)]
  end
end
