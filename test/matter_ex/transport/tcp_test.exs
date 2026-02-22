defmodule MatterEx.Transport.TCPTest do
  use ExUnit.Case, async: true

  alias MatterEx.Transport.TCP

  describe "frame/1" do
    test "adds 4-byte little-endian length prefix" do
      framed = TCP.frame("hello")
      assert framed == <<5, 0, 0, 0, "hello">>
    end

    test "empty message" do
      assert TCP.frame(<<>>) == <<0, 0, 0, 0>>
    end

    test "large message length encoded correctly" do
      msg = :crypto.strong_rand_bytes(300)
      <<len::little-32, payload::binary>> = TCP.frame(msg)
      assert len == 300
      assert payload == msg
    end
  end

  describe "parse/1" do
    test "parses single complete message" do
      buffer = <<5, 0, 0, 0, "hello">>
      assert {["hello"], <<>>} = TCP.parse(buffer)
    end

    test "parses multiple messages" do
      buffer = <<5, 0, 0, 0, "hello", 3, 0, 0, 0, "bye">>
      {messages, remaining} = TCP.parse(buffer)
      assert messages == ["hello", "bye"]
      assert remaining == <<>>
    end

    test "handles incomplete length header" do
      buffer = <<5, 0>>
      assert {[], ^buffer} = TCP.parse(buffer)
    end

    test "handles incomplete message body" do
      buffer = <<10, 0, 0, 0, "short">>
      assert {[], ^buffer} = TCP.parse(buffer)
    end

    test "parses complete messages and keeps remainder" do
      buffer = <<5, 0, 0, 0, "hello", 10, 0, 0, 0, "par">>
      {messages, remaining} = TCP.parse(buffer)
      assert messages == ["hello"]
      assert remaining == <<10, 0, 0, 0, "par">>
    end

    test "empty buffer returns empty" do
      assert {[], <<>>} = TCP.parse(<<>>)
    end

    test "round-trip: frame then parse" do
      msg1 = :crypto.strong_rand_bytes(100)
      msg2 = :crypto.strong_rand_bytes(200)
      buffer = TCP.frame(msg1) <> TCP.frame(msg2)
      {messages, remaining} = TCP.parse(buffer)
      assert messages == [msg1, msg2]
      assert remaining == <<>>
    end
  end
end
