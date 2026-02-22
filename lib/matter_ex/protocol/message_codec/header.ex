defmodule MatterEx.Protocol.MessageCodec.Header do
  @moduledoc """
  Matter message header (plaintext).

  Wire format (Matter spec section 4.4.1):

      [msg_flags:8] [session_id:16LE] [sec_flags:8] [counter:32LE]
      [source_node_id:64LE if S] [dest_node_id:64LE if DSIZ=01 | dest_group_id:16LE if DSIZ=10]
  """

  import Bitwise

  # Message Flags (byte 0)
  @flag_s 0x04
  @dsiz_mask 0x03
  @dsiz_none 0x00
  @dsiz_node_id 0x01
  @dsiz_group_id 0x02

  # Security Flags (byte 3)
  @flag_p 0x80
  @flag_c 0x40
  @session_type_mask 0x03

  @type t :: %__MODULE__{
    version: 0..15,
    session_id: non_neg_integer(),
    security_flags: byte(),
    message_counter: non_neg_integer(),
    source_node_id: non_neg_integer() | nil,
    dest_node_id: non_neg_integer() | nil,
    dest_group_id: non_neg_integer() | nil,
    session_type: :unicast | :group,
    privacy: boolean(),
    control_message: boolean()
  }

  defstruct version: 0,
            session_id: 0,
            security_flags: 0,
            message_counter: 0,
            source_node_id: nil,
            dest_node_id: nil,
            dest_group_id: nil,
            session_type: :unicast,
            privacy: false,
            control_message: false

  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{} = h) do
    dsiz = dsiz_bits(h.dest_node_id, h.dest_group_id)
    s_bit = if h.source_node_id != nil, do: @flag_s, else: 0
    msg_flags = (h.version <<< 4) ||| s_bit ||| dsiz

    sec_flags = build_security_flags(h)

    src_part = if h.source_node_id != nil, do: <<h.source_node_id::little-64>>, else: []
    dest_part = encode_dest(h.dest_node_id, h.dest_group_id)

    [
      <<msg_flags::8, h.session_id::little-16, sec_flags::8, h.message_counter::little-32>>,
      src_part,
      dest_part
    ]
  end

  @spec decode(binary()) :: {:ok, t(), binary()} | {:error, atom()}
  def decode(<<msg_flags::8, session_id::little-16, sec_flags::8,
               counter::little-32, rest::binary>>) do
    version = (msg_flags &&& 0xF0) >>> 4
    has_source = (msg_flags &&& @flag_s) != 0
    dsiz = msg_flags &&& @dsiz_mask

    with {:ok, source_id, rest} <- decode_source(has_source, rest),
         {:ok, dest_node, dest_group, rest} <- decode_dest(dsiz, rest) do
      header = %__MODULE__{
        version: version,
        session_id: session_id,
        security_flags: sec_flags,
        message_counter: counter,
        source_node_id: source_id,
        dest_node_id: dest_node,
        dest_group_id: dest_group,
        session_type: if((sec_flags &&& @session_type_mask) == 1, do: :group, else: :unicast),
        privacy: (sec_flags &&& @flag_p) != 0,
        control_message: (sec_flags &&& @flag_c) != 0
      }

      {:ok, header, rest}
    end
  end

  def decode(_), do: {:error, :truncated_header}

  # ── Private ─────────────────────────────────────────────────────

  defp build_security_flags(%__MODULE__{} = h) do
    p = if h.privacy, do: @flag_p, else: 0
    c = if h.control_message, do: @flag_c, else: 0
    st = if h.session_type == :group, do: 1, else: 0
    p ||| c ||| st
  end

  defp dsiz_bits(nil, nil), do: @dsiz_none
  defp dsiz_bits(_node_id, nil), do: @dsiz_node_id
  defp dsiz_bits(nil, _group_id), do: @dsiz_group_id

  defp encode_dest(nil, nil), do: []
  defp encode_dest(node_id, nil), do: <<node_id::little-64>>
  defp encode_dest(nil, group_id), do: <<group_id::little-16>>

  defp decode_source(false, rest), do: {:ok, nil, rest}

  defp decode_source(true, <<src::little-64, rest::binary>>), do: {:ok, src, rest}

  defp decode_source(true, _), do: {:error, :truncated_header}

  defp decode_dest(@dsiz_none, rest), do: {:ok, nil, nil, rest}

  defp decode_dest(@dsiz_node_id, <<node_id::little-64, rest::binary>>),
    do: {:ok, node_id, nil, rest}

  defp decode_dest(@dsiz_group_id, <<group_id::little-16, rest::binary>>),
    do: {:ok, nil, group_id, rest}

  defp decode_dest(@dsiz_node_id, _), do: {:error, :truncated_header}
  defp decode_dest(@dsiz_group_id, _), do: {:error, :truncated_header}
  defp decode_dest(_, _), do: {:error, :invalid_dsiz}
end
