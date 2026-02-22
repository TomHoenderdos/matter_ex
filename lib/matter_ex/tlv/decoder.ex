defmodule MatterEx.TLV.Decoder do
  @moduledoc false

  import Bitwise

  @doc """
  Decode one TLV element from binary.

  Returns `{tag, value, rest}` where:
  - `tag` is `:anonymous`, an integer (context tag), or a tuple for profile tags
  - `value` is the decoded Elixir value
  - `rest` is the remaining binary after this element
  """
  @spec decode_element(binary()) :: {term(), term(), binary()}
  def decode_element(<<control, rest::binary>>) do
    tag_control = (control >>> 5) &&& 0x07
    elem_type = control &&& 0x1F

    {tag, rest} = decode_tag(tag_control, rest)
    {value, rest} = decode_value(elem_type, rest)

    {tag, value, rest}
  end

  ## Tag decoding

  defp decode_tag(0, rest), do: {:anonymous, rest}

  defp decode_tag(1, <<tag::unsigned-8, rest::binary>>), do: {tag, rest}

  defp decode_tag(2, <<tag::little-unsigned-16, rest::binary>>),
    do: {{:common, tag}, rest}

  defp decode_tag(3, <<tag::little-unsigned-32, rest::binary>>),
    do: {{:common, tag}, rest}

  defp decode_tag(4, <<tag::little-unsigned-16, rest::binary>>),
    do: {{:implicit, tag}, rest}

  defp decode_tag(5, <<tag::little-unsigned-32, rest::binary>>),
    do: {{:implicit, tag}, rest}

  defp decode_tag(6, <<vendor::little-unsigned-16, profile::little-unsigned-16,
                       tag::little-unsigned-16, rest::binary>>),
    do: {{:fq, vendor, profile, tag}, rest}

  defp decode_tag(7, <<vendor::little-unsigned-16, profile::little-unsigned-16,
                       tag::little-unsigned-32, rest::binary>>),
    do: {{:fq, vendor, profile, tag}, rest}

  ## Value decoding — signed integers

  defp decode_value(0x00, <<v::little-signed-8, rest::binary>>), do: {v, rest}
  defp decode_value(0x01, <<v::little-signed-16, rest::binary>>), do: {v, rest}
  defp decode_value(0x02, <<v::little-signed-32, rest::binary>>), do: {v, rest}
  defp decode_value(0x03, <<v::little-signed-64, rest::binary>>), do: {v, rest}

  ## Value decoding — unsigned integers

  defp decode_value(0x04, <<v::little-unsigned-8, rest::binary>>), do: {v, rest}
  defp decode_value(0x05, <<v::little-unsigned-16, rest::binary>>), do: {v, rest}
  defp decode_value(0x06, <<v::little-unsigned-32, rest::binary>>), do: {v, rest}
  defp decode_value(0x07, <<v::little-unsigned-64, rest::binary>>), do: {v, rest}

  ## Value decoding — booleans (encoded in element type, no value bytes)

  defp decode_value(0x08, rest), do: {false, rest}
  defp decode_value(0x09, rest), do: {true, rest}

  ## Value decoding — floating point

  defp decode_value(0x0A, <<v::little-float-32, rest::binary>>), do: {v, rest}
  defp decode_value(0x0B, <<v::little-float-64, rest::binary>>), do: {v, rest}

  ## Value decoding — UTF-8 strings (1/2/4/8-byte length prefix)

  defp decode_value(0x0C, <<len::little-unsigned-8, rest::binary>>),
    do: read_bytes(len, rest)

  defp decode_value(0x0D, <<len::little-unsigned-16, rest::binary>>),
    do: read_bytes(len, rest)

  defp decode_value(0x0E, <<len::little-unsigned-32, rest::binary>>),
    do: read_bytes(len, rest)

  defp decode_value(0x0F, <<len::little-unsigned-64, rest::binary>>),
    do: read_bytes(len, rest)

  ## Value decoding — byte strings (1/2/4/8-byte length prefix)

  defp decode_value(0x10, <<len::little-unsigned-8, rest::binary>>),
    do: read_bytes(len, rest)

  defp decode_value(0x11, <<len::little-unsigned-16, rest::binary>>),
    do: read_bytes(len, rest)

  defp decode_value(0x12, <<len::little-unsigned-32, rest::binary>>),
    do: read_bytes(len, rest)

  defp decode_value(0x13, <<len::little-unsigned-64, rest::binary>>),
    do: read_bytes(len, rest)

  ## Value decoding — null

  defp decode_value(0x14, rest), do: {nil, rest}

  ## Value decoding — containers

  defp decode_value(0x15, rest), do: decode_container_map(rest, %{})
  defp decode_value(0x16, rest), do: decode_container_list(rest, [])
  defp decode_value(0x17, rest), do: decode_container_map(rest, %{})

  ## Container helpers

  # Struct: collect tagged elements into a map
  defp decode_container_map(<<0x18, rest::binary>>, acc), do: {acc, rest}

  defp decode_container_map(binary, acc) do
    {tag, value, rest} = decode_element(binary)

    key =
      case tag do
        :anonymous -> map_size(acc)
        n when is_integer(n) -> n
        {:common, n} -> n
        {:implicit, n} -> n
        {:fq, _v, _p, n} -> n
      end

    decode_container_map(rest, Map.put(acc, key, value))
  end

  # Array/List: collect elements into a list
  defp decode_container_list(<<0x18, rest::binary>>, acc), do: {Enum.reverse(acc), rest}

  defp decode_container_list(binary, acc) do
    {_tag, value, rest} = decode_element(binary)
    decode_container_list(rest, [value | acc])
  end

  ## Shared helpers

  defp read_bytes(len, binary) do
    <<data::binary-size(len), rest::binary>> = binary
    {data, rest}
  end
end
