defmodule MatterEx.Transport.TCP do
  @moduledoc """
  Matter TCP message framing.

  Matter over TCP uses a 4-byte little-endian length prefix before each message.
  This module handles encoding (framing) and decoding (parsing) of length-prefixed
  messages from a TCP byte stream.
  """

  @doc """
  Frame a message with a 4-byte little-endian length prefix.
  """
  @spec frame(binary()) :: binary()
  def frame(message) when is_binary(message) do
    <<byte_size(message)::little-32, message::binary>>
  end

  @doc """
  Parse complete messages from a TCP buffer.

  Returns `{messages, remaining_buffer}` where messages is a list of
  complete message binaries and remaining_buffer holds any incomplete data.
  """
  @spec parse(binary()) :: {[binary()], binary()}
  def parse(buffer) when is_binary(buffer) do
    parse_messages(buffer, [])
  end

  defp parse_messages(<<len::little-32, rest::binary>>, acc) when byte_size(rest) >= len do
    <<message::binary-size(len), remaining::binary>> = rest
    parse_messages(remaining, [message | acc])
  end

  defp parse_messages(buffer, acc) do
    {Enum.reverse(acc), buffer}
  end
end
