defmodule MatterEx.Protocol.MessageCodec.ProtoHeader do
  @moduledoc false

  # Matter protocol header (part of encrypted payload).
  #
  # Wire format (Matter spec section 4.4.2):
  #   [exch_flags:8] [opcode:8] [exchange_id:16LE]
  #   [vendor_id:16LE if V] [protocol_id:16LE]
  #   [ack_counter:32LE if A] [payload]

  import Bitwise

  # Exchange Flags (byte 0)
  @flag_i 0x01
  @flag_a 0x02
  @flag_r 0x04
  @flag_v 0x10

  @type t :: %__MODULE__{
    initiator: boolean(),
    needs_ack: boolean(),
    ack_counter: non_neg_integer() | nil,
    vendor_id: non_neg_integer() | nil,
    opcode: byte(),
    exchange_id: non_neg_integer(),
    protocol_id: non_neg_integer(),
    payload: binary()
  }

  defstruct initiator: false,
            needs_ack: false,
            ack_counter: nil,
            vendor_id: nil,
            opcode: 0,
            exchange_id: 0,
            protocol_id: 0,
            payload: <<>>

  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{} = ph) do
    flags =
      (if ph.initiator, do: @flag_i, else: 0) |||
        (if ph.ack_counter != nil, do: @flag_a, else: 0) |||
        (if ph.needs_ack, do: @flag_r, else: 0) |||
        (if ph.vendor_id != nil, do: @flag_v, else: 0)

    vendor_part = if ph.vendor_id != nil, do: <<ph.vendor_id::little-16>>, else: []
    ack_part = if ph.ack_counter != nil, do: <<ph.ack_counter::little-32>>, else: []

    [
      <<flags::8, ph.opcode::8, ph.exchange_id::little-16>>,
      vendor_part,
      <<ph.protocol_id::little-16>>,
      ack_part,
      ph.payload
    ]
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(<<flags::8, opcode::8, exchange_id::little-16, rest::binary>>) do
    has_vendor = (flags &&& @flag_v) != 0
    has_ack = (flags &&& @flag_a) != 0

    with {:ok, vendor_id, rest} <- decode_vendor(has_vendor, rest),
         {:ok, protocol_id, rest} <- decode_u16le(rest),
         {:ok, ack_counter, rest} <- decode_ack(has_ack, rest) do
      {:ok,
       %__MODULE__{
         initiator: (flags &&& @flag_i) != 0,
         needs_ack: (flags &&& @flag_r) != 0,
         ack_counter: ack_counter,
         vendor_id: vendor_id,
         opcode: opcode,
         exchange_id: exchange_id,
         protocol_id: protocol_id,
         payload: rest
       }}
    end
  end

  def decode(_), do: {:error, :truncated_proto_header}

  # ── Private ─────────────────────────────────────────────────────

  defp decode_vendor(false, rest), do: {:ok, nil, rest}
  defp decode_vendor(true, <<v::little-16, rest::binary>>), do: {:ok, v, rest}
  defp decode_vendor(true, _), do: {:error, :truncated_proto_header}

  defp decode_u16le(<<v::little-16, rest::binary>>), do: {:ok, v, rest}
  defp decode_u16le(_), do: {:error, :truncated_proto_header}

  defp decode_ack(false, rest), do: {:ok, nil, rest}
  defp decode_ack(true, <<c::little-32, rest::binary>>), do: {:ok, c, rest}
  defp decode_ack(true, _), do: {:error, :truncated_proto_header}
end
