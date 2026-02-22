defmodule MatterEx.Transport.BTP.Packet do
  @moduledoc false

  # BTP packet binary encoding and decoding.
  #
  # Wire format for data packets:
  #   [flags:8] [ack:8 if A] [seq:8] [msg_len:16LE if B] [payload]
  #
  # Wire format for ack-only packets:
  #   [flags:8 with A=1] [ack:8]
  #
  # Wire format for handshake request:
  #   [flags:8 H|M] [opcode:8=0x6C] [versions:32] [mtu:16LE] [window_size:8]
  #
  # Wire format for handshake response:
  #   [flags:8 H|M] [opcode:8=0x6C] [selected_version:16LE] [mtu:16LE] [window_size:8]

  import Bitwise

  # Flags byte bit positions
  @flag_h 0x01
  @flag_m 0x02
  @flag_a 0x04
  @flag_e 0x08
  @flag_b 0x10

  @handshake_opcode 0x6C

  def flags, do: %{h: @flag_h, m: @flag_m, a: @flag_a, e: @flag_e, b: @flag_b}

  @doc """
  Encode a BTP data packet into iodata.

  Fields:
  - `:flags` — flags byte (integer)
  - `:ack` — ack number (integer or nil)
  - `:seq` — sequence number (integer)
  - `:msg_len` — total message length (integer or nil, present when B flag set)
  - `:payload` — binary payload
  """
  @spec encode_data(map()) :: iodata()
  def encode_data(%{flags: flags, seq: seq, payload: payload} = fields) do
    ack_part = if (flags &&& @flag_a) != 0, do: <<fields.ack::8>>, else: []
    len_part = if (flags &&& @flag_b) != 0, do: <<fields.msg_len::little-16>>, else: []
    [<<flags::8>>, ack_part, <<seq::8>>, len_part, payload]
  end

  @doc """
  Encode an ack-only packet.
  """
  @spec encode_ack(non_neg_integer()) :: iodata()
  def encode_ack(ack_num) do
    [<<@flag_a::8>>, <<ack_num::8>>]
  end

  @doc """
  Encode a BTP handshake request.
  """
  @spec encode_handshake_request(binary(), non_neg_integer(), non_neg_integer()) :: iodata()
  def encode_handshake_request(versions, mtu, window_size) do
    [<<@flag_h ||| @flag_m>>, <<@handshake_opcode>>, versions, <<mtu::little-16>>, <<window_size::8>>]
  end

  @doc """
  Encode a BTP handshake response.
  """
  @spec encode_handshake_response(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: iodata()
  def encode_handshake_response(selected_version, mtu, window_size) do
    [<<@flag_h ||| @flag_m>>, <<@handshake_opcode>>, <<selected_version::little-16>>, <<mtu::little-16>>, <<window_size::8>>]
  end

  @doc """
  Decode a BTP packet binary.

  Returns:
  - `{:data, map}` — data packet with `:flags`, `:ack`, `:seq`, `:msg_len`, `:payload`, `:beginning`, `:ending`
  - `{:ack_only, ack_num}` — ack-only packet
  - `{:handshake_request, map}` — with `:versions`, `:mtu`, `:window_size`
  - `{:handshake_response, map}` — with `:selected_version`, `:mtu`, `:window_size`
  - `{:error, reason}` — decode failure
  """
  @spec decode(binary()) :: {atom(), term()} | {:error, atom()}

  # Handshake request: H|M flags, opcode 0x6C, 4-byte versions + 2-byte mtu + 1-byte window
  def decode(<<flags, @handshake_opcode, v0, v1, v2, v3,
               mtu::little-unsigned-16, ws::8>>)
      when (flags &&& (@flag_h ||| @flag_m)) == (@flag_h ||| @flag_m) and
           byte_size(<<v0, v1, v2, v3>>) == 4 do
    {:handshake_request, %{versions: <<v0, v1, v2, v3>>, mtu: mtu, window_size: ws}}
  end

  # Handshake response: H|M flags, opcode 0x6C, 2-byte version + 2-byte mtu + 1-byte window
  def decode(<<flags, @handshake_opcode, sv::little-unsigned-16,
               mtu::little-unsigned-16, ws::8>>)
      when (flags &&& (@flag_h ||| @flag_m)) == (@flag_h ||| @flag_m) do
    {:handshake_response, %{selected_version: sv, mtu: mtu, window_size: ws}}
  end

  # Ack-only: A flag set, no B, no E, just ack number, no more data
  def decode(<<flags, ack_num::8>>)
      when (flags &&& @flag_a) != 0 and
           (flags &&& @flag_b) == 0 and
           (flags &&& @flag_e) == 0 do
    {:ack_only, ack_num}
  end

  # Data packet with A flag (ack + data)
  def decode(<<flags, ack_num::8, rest::binary>>)
      when (flags &&& @flag_a) != 0 and
           (flags &&& (@flag_h ||| @flag_m)) == 0 do
    decode_data_body(flags, ack_num, rest)
  end

  # Data packet without A flag
  def decode(<<flags, rest::binary>>)
      when (flags &&& @flag_a) == 0 and
           (flags &&& (@flag_h ||| @flag_m)) == 0 do
    decode_data_body(flags, nil, rest)
  end

  def decode(_binary), do: {:error, :invalid_packet}

  # Data body: [seq] [msg_len:16LE if B] [payload]
  defp decode_data_body(flags, ack, <<seq::8, rest::binary>>) do
    beginning? = (flags &&& @flag_b) != 0
    ending? = (flags &&& @flag_e) != 0

    {msg_len, payload} =
      if beginning? do
        <<len::little-unsigned-16, p::binary>> = rest
        {len, p}
      else
        {nil, rest}
      end

    {:data, %{
      flags: flags,
      ack: ack,
      seq: seq,
      msg_len: msg_len,
      beginning: beginning?,
      ending: ending?,
      payload: payload
    }}
  end

  defp decode_data_body(_flags, _ack, _rest), do: {:error, :truncated}
end
