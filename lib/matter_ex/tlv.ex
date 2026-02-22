defmodule MatterEx.TLV do
  @moduledoc """
  Matter TLV (Tag-Length-Value) encoder/decoder.

  Matter TLV is a compact binary serialization format defined in the Matter
  specification (Appendix A). It is used for all structured data in the Matter
  protocol: messages, attributes, commands, and commissioning payloads.

  ## Encoding

      MatterEx.TLV.encode(%{
        1 => {:uint, 42},
        2 => {:string, "hello"},
        3 => {:struct, %{0 => {:bool, true}}}
      })
      #=> <<0x15, ...>>

  ## Decoding

      MatterEx.TLV.decode(<<0x15, ...>>)
      #=> %{1 => 42, 2 => "hello", 3 => %{0 => true}}

  ## Supported types

  Encoding uses tagged tuples to specify the wire type:

    - `{:uint, non_neg_integer}` — unsigned integer (1/2/4/8 bytes, auto-sized)
    - `{:int, integer}` — signed integer (1/2/4/8 bytes, auto-sized)
    - `{:bool, boolean}` — boolean
    - `{:float, float}` — IEEE 754 single-precision (32-bit)
    - `{:double, float}` — IEEE 754 double-precision (64-bit)
    - `{:string, binary}` — UTF-8 string
    - `{:bytes, binary}` — byte string
    - `:null` — null value
    - `{:struct, map}` — structure (map with integer context tags)
    - `{:array, list}` — array (ordered, anonymous elements)
    - `{:list, list | map}` — list (ordered, may have tags)

  Decoding returns plain Elixir values: integers, booleans, floats, binaries,
  nil, maps (for structs), and lists (for arrays/lists).
  """

  alias MatterEx.TLV.{Encoder, Decoder}

  @doc """
  Encode a map as a TLV anonymous struct.

  Keys are context-specific tag numbers (0-255). Values are tagged tuples.
  """
  @spec encode(map()) :: binary()
  def encode(data) when is_map(data) do
    Encoder.encode_struct(data)
  end

  @doc """
  Decode a TLV binary into Elixir values.

  Structs become maps with integer keys. Arrays and lists become lists.
  Scalars become their native Elixir type.
  """
  @spec decode(binary()) :: term()
  def decode(binary) when is_binary(binary) do
    {_tag, value, _rest} = Decoder.decode_element(binary)
    value
  end
end
