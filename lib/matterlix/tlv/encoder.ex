defmodule Matterlix.TLV.Encoder do
  @moduledoc false

  import Bitwise

  # Matter TLV element types (control byte bits 4:0)
  @int8 0x00
  @int16 0x01
  @int32 0x02
  @int64 0x03
  @uint8 0x04
  @uint16 0x05
  @uint32 0x06
  @uint64 0x07
  @bool_false 0x08
  @bool_true 0x09
  @float32 0x0A
  @float64 0x0B
  @utf8_1byte 0x0C
  @bytes_1byte 0x10
  @null 0x14
  @struct_type 0x15
  @array_type 0x16
  @list_type 0x17
  @end_of_container 0x18

  # Tag control values (control byte bits 7:5)
  @tag_anonymous 0
  @tag_context 1

  @doc false
  @spec encode_struct(map()) :: binary()
  def encode_struct(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map(fn {tag, value} -> encode_context(tag, value) end)

    IO.iodata_to_binary([control(@tag_anonymous, @struct_type), inner, <<@end_of_container>>])
  end

  @doc false
  @spec encode_anonymous(term()) :: binary()
  def encode_anonymous(value) do
    encode_with_tag(@tag_anonymous, <<>>, value)
  end

  @doc false
  @spec encode_context(non_neg_integer(), term()) :: binary()
  def encode_context(tag, value) when is_integer(tag) and tag in 0..255 do
    encode_with_tag(@tag_context, <<tag::8>>, value)
  end

  # Unsigned integers — choose smallest encoding
  defp encode_with_tag(tc, tag, {:uint, n}) when n in 0..0xFF do
    [control(tc, @uint8), tag, <<n::little-unsigned-8>>]
  end

  defp encode_with_tag(tc, tag, {:uint, n}) when n in 0..0xFFFF do
    [control(tc, @uint16), tag, <<n::little-unsigned-16>>]
  end

  defp encode_with_tag(tc, tag, {:uint, n}) when n in 0..0xFFFFFFFF do
    [control(tc, @uint32), tag, <<n::little-unsigned-32>>]
  end

  defp encode_with_tag(tc, tag, {:uint, n}) when n >= 0 do
    [control(tc, @uint64), tag, <<n::little-unsigned-64>>]
  end

  # Signed integers — choose smallest encoding
  defp encode_with_tag(tc, tag, {:int, n}) when n in -128..127 do
    [control(tc, @int8), tag, <<n::little-signed-8>>]
  end

  defp encode_with_tag(tc, tag, {:int, n}) when n in -32_768..32_767 do
    [control(tc, @int16), tag, <<n::little-signed-16>>]
  end

  defp encode_with_tag(tc, tag, {:int, n}) when n in -2_147_483_648..2_147_483_647 do
    [control(tc, @int32), tag, <<n::little-signed-32>>]
  end

  defp encode_with_tag(tc, tag, {:int, n}) when is_integer(n) do
    [control(tc, @int64), tag, <<n::little-signed-64>>]
  end

  # Booleans — encoded in the element type, no value bytes
  defp encode_with_tag(tc, tag, {:bool, false}) do
    [control(tc, @bool_false), tag]
  end

  defp encode_with_tag(tc, tag, {:bool, true}) do
    [control(tc, @bool_true), tag]
  end

  # Floating point
  defp encode_with_tag(tc, tag, {:float, f}) do
    [control(tc, @float32), tag, <<f::little-float-32>>]
  end

  defp encode_with_tag(tc, tag, {:double, f}) do
    [control(tc, @float64), tag, <<f::little-float-64>>]
  end

  # UTF-8 strings — choose smallest length prefix
  defp encode_with_tag(tc, tag, {:string, s}) when is_binary(s) do
    len = byte_size(s)
    {elem_type, len_bytes} = length_prefix(len, @utf8_1byte)
    [control(tc, elem_type), tag, len_bytes, s]
  end

  # Byte strings — choose smallest length prefix
  defp encode_with_tag(tc, tag, {:bytes, b}) when is_binary(b) do
    len = byte_size(b)
    {elem_type, len_bytes} = length_prefix(len, @bytes_1byte)
    [control(tc, elem_type), tag, len_bytes, b]
  end

  # Null
  defp encode_with_tag(tc, tag, :null) do
    [control(tc, @null), tag]
  end

  # Struct (nested)
  defp encode_with_tag(tc, tag, {:struct, map}) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map(fn {t, v} -> encode_context(t, v) end)

    [control(tc, @struct_type), tag, inner, <<@end_of_container>>]
  end

  # Array — all elements anonymous
  defp encode_with_tag(tc, tag, {:array, list}) when is_list(list) do
    inner = Enum.map(list, &encode_anonymous/1)
    [control(tc, @array_type), tag, inner, <<@end_of_container>>]
  end

  # List with anonymous elements
  defp encode_with_tag(tc, tag, {:list, list}) when is_list(list) do
    inner = Enum.map(list, &encode_anonymous/1)
    [control(tc, @list_type), tag, inner, <<@end_of_container>>]
  end

  # List with tagged elements (map)
  defp encode_with_tag(tc, tag, {:list, map}) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map(fn {t, v} -> encode_context(t, v) end)

    [control(tc, @list_type), tag, inner, <<@end_of_container>>]
  end

  # Auto-tag raw values (from TLV decoder round-trip)
  defp encode_with_tag(tc, tag, b) when is_boolean(b) do
    encode_with_tag(tc, tag, {:bool, b})
  end

  defp encode_with_tag(tc, tag, n) when is_integer(n) and n >= 0 do
    encode_with_tag(tc, tag, {:uint, n})
  end

  defp encode_with_tag(tc, tag, n) when is_integer(n) do
    encode_with_tag(tc, tag, {:int, n})
  end

  defp encode_with_tag(tc, tag, s) when is_binary(s) do
    encode_with_tag(tc, tag, {:bytes, s})
  end

  defp encode_with_tag(tc, tag, nil) do
    encode_with_tag(tc, tag, :null)
  end

  defp encode_with_tag(tc, tag, list) when is_list(list) do
    encode_with_tag(tc, tag, {:array, list})
  end

  defp encode_with_tag(tc, tag, map) when is_map(map) do
    encode_with_tag(tc, tag, {:struct, map})
  end

  # Build control byte: (tag_control << 5) | element_type
  defp control(tag_control, elem_type) do
    <<(tag_control <<< 5) ||| elem_type>>
  end

  # Choose smallest length prefix for strings/bytes
  # base_type is the 1-byte-length variant; +1 = 2-byte, +2 = 4-byte, +3 = 8-byte
  defp length_prefix(len, base) when len <= 0xFF do
    {base, <<len::little-unsigned-8>>}
  end

  defp length_prefix(len, base) when len <= 0xFFFF do
    {base + 1, <<len::little-unsigned-16>>}
  end

  defp length_prefix(len, base) when len <= 0xFFFFFFFF do
    {base + 2, <<len::little-unsigned-32>>}
  end

  defp length_prefix(len, base) do
    {base + 3, <<len::little-unsigned-64>>}
  end
end
