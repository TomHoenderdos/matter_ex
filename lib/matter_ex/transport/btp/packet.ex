defmodule MatterEx.Transport.BTP.Packet do
  @moduledoc false

  # BTP packet binary encoding and decoding.
  #
  # Wire format for data packets:
  #   [flags:8] [ack:8 if A] [seq:8] [msg_len:16LE if Start] [payload]
  #
  # Wire format for ack-only packets:
  #   [flags:8 with A=1] [ack:8] [seq:8]
  #
  # Wire format for capabilities request:
  #   [magic:16=0x65,0x6c] [versions:32] [mtu:16LE] [window_size:8]
  #
  # Wire format for capabilities response:
  #   [magic:16=0x65,0x6c] [selected_version:8] [fragment_size:16LE] [window_size:8]

  import Bitwise

  # CHIP BTP header flags.
  @flag_s 0x01
  @flag_c 0x02
  @flag_e 0x04
  @flag_a 0x08

  @capabilities_magic <<0x65, 0x6C>>

  def flags, do: %{s: @flag_s, c: @flag_c, e: @flag_e, a: @flag_a}

  @doc """
  Encode a BTP data packet into iodata.

  Fields:
  - `:flags` — flags byte (integer)
  - `:ack` — ack number (integer or nil)
  - `:seq` — sequence number (integer)
  - `:msg_len` — total message length (integer or nil, present when Start flag set)
  - `:payload` — binary payload
  """
  @spec encode_data(map()) :: iodata()
  def encode_data(%{flags: flags, seq: seq, payload: payload} = fields) do
    ack_part = if (flags &&& @flag_a) != 0, do: <<fields.ack::8>>, else: []
    len_part = if (flags &&& @flag_s) != 0, do: <<fields.msg_len::little-16>>, else: []
    [<<flags::8>>, ack_part, <<seq::8>>, len_part, payload]
  end

  @doc """
  Encode an ack-only packet.
  """
  @spec encode_ack(non_neg_integer(), non_neg_integer()) :: iodata()
  def encode_ack(ack_num, seq \\ 0) do
    [<<@flag_a::8>>, <<ack_num::8>>, <<seq::8>>]
  end

  @doc """
  Encode a BTP handshake request.
  """
  @spec encode_handshake_request(binary(), non_neg_integer(), non_neg_integer()) :: iodata()
  def encode_handshake_request(versions, mtu, window_size) do
    [
      @capabilities_magic,
      versions,
      <<mtu::little-16>>,
      <<window_size::8>>
    ]
  end

  @doc """
  Encode a BTP handshake response.
  """
  @spec encode_handshake_response(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          iodata()
  def encode_handshake_response(selected_version, mtu, window_size) do
    [
      @capabilities_magic,
      <<selected_version::8>>,
      <<mtu::little-16>>,
      <<window_size::8>>
    ]
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

  # Capabilities request: magic, 4-byte versions + 2-byte mtu + 1-byte window.
  def decode(<<@capabilities_magic, v0, v1, v2, v3, mtu::little-unsigned-16, ws::8>>) do
    {:handshake_request, %{versions: <<v0, v1, v2, v3>>, mtu: mtu, window_size: ws}}
  end

  # Some Linux chip-tool builds have been observed sending an 8-byte request
  # with MTU omitted/zero: magic, versions, zero, window.
  def decode(<<@capabilities_magic, v0, v1, v2, v3, 0, ws::8>>) do
    {:handshake_request, %{versions: <<v0, v1, v2, v3>>, mtu: 0, window_size: ws}}
  end

  # Capabilities response: magic, 1-byte selected version + 2-byte fragment size + 1-byte window.
  def decode(<<@capabilities_magic, sv::8, mtu::little-unsigned-16, ws::8>>) do
    {:handshake_response, %{selected_version: sv, mtu: mtu, window_size: ws}}
  end

  # Ack-only: A flag set, no Start/Continue/End data bits.
  def decode(<<flags, ack_num::8, _seq::8>>)
      when (flags &&& @flag_a) != 0 and
             (flags &&& (@flag_s ||| @flag_c ||| @flag_e)) == 0 do
    {:ack_only, ack_num}
  end

  # Backwards-compatible parser for older tests/local callers.
  def decode(<<flags, ack_num::8>>)
      when (flags &&& @flag_a) != 0 and
             (flags &&& (@flag_s ||| @flag_c ||| @flag_e)) == 0 do
    {:ack_only, ack_num}
  end

  # Data packet with A flag (ack + data)
  def decode(<<flags, ack_num::8, rest::binary>>)
      when (flags &&& @flag_a) != 0 and
             (flags &&& (@flag_s ||| @flag_c ||| @flag_e)) != 0 do
    decode_data_body(flags, ack_num, rest)
  end

  # Data packet without A flag
  def decode(<<flags, rest::binary>>)
      when (flags &&& @flag_a) == 0 and
             (flags &&& (@flag_s ||| @flag_c ||| @flag_e)) != 0 do
    decode_data_body(flags, nil, rest)
  end

  # CHIP treats a no-data, no-ack header as invalid.
  def decode(<<flags, _rest::binary>>)
      when (flags &&& @flag_a) == 0 and
             (flags &&& (@flag_s ||| @flag_c ||| @flag_e)) == 0 do
    {:error, :invalid_packet}
  end

  def decode(_binary), do: {:error, :invalid_packet}

  # Data body: [seq] [msg_len:16LE if Start] [payload]
  defp decode_data_body(flags, ack, <<seq::8, rest::binary>>) do
    beginning? = (flags &&& @flag_s) != 0
    ending? = (flags &&& @flag_e) != 0

    {msg_len, payload} =
      if beginning? do
        <<len::little-unsigned-16, p::binary>> = rest
        {len, p}
      else
        {nil, rest}
      end

    {:data,
     %{
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
