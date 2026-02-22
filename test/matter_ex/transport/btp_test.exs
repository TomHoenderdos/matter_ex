defmodule MatterEx.Transport.BTPTest do
  use ExUnit.Case, async: true

  alias MatterEx.Transport.BTP
  alias MatterEx.Transport.BTP.Packet

  # ── Packet Encoding ────────────────────────────────────────────────

  describe "packet encoding" do
    test "single-fragment data packet (B|E)" do
      packet =
        IO.iodata_to_binary(
          Packet.encode_data(%{flags: 0x18, ack: nil, seq: 0, msg_len: 5, payload: "hello"})
        )

      # flags=0x18 (B|E), seq=0, msg_len=5 LE, "hello"
      assert <<0x18, 0x00, 0x05, 0x00, "hello">> == packet
    end

    test "beginning-only fragment (B flag)" do
      packet =
        IO.iodata_to_binary(
          Packet.encode_data(%{flags: 0x10, ack: nil, seq: 0, msg_len: 100, payload: "abc"})
        )

      assert <<0x10, 0x00, 100, 0x00, "abc">> == packet
    end

    test "middle fragment (no B, no E)" do
      packet =
        IO.iodata_to_binary(
          Packet.encode_data(%{flags: 0x00, ack: nil, seq: 1, msg_len: nil, payload: "xyz"})
        )

      assert <<0x00, 0x01, "xyz">> == packet
    end

    test "ending fragment (E flag)" do
      packet =
        IO.iodata_to_binary(
          Packet.encode_data(%{flags: 0x08, ack: nil, seq: 2, msg_len: nil, payload: "end"})
        )

      assert <<0x08, 0x02, "end">> == packet
    end

    test "data packet with ack" do
      packet =
        IO.iodata_to_binary(
          Packet.encode_data(%{flags: 0x1C, ack: 5, seq: 3, msg_len: 10, payload: "hi"})
        )

      # flags=0x1C (B|E|A), ack=5, seq=3, msg_len=10 LE, "hi"
      assert <<0x1C, 0x05, 0x03, 0x0A, 0x00, "hi">> == packet
    end

    test "ack-only packet" do
      packet = IO.iodata_to_binary(Packet.encode_ack(42))
      assert <<0x04, 42>> == packet
    end

    test "empty payload" do
      packet =
        IO.iodata_to_binary(
          Packet.encode_data(%{flags: 0x18, ack: nil, seq: 0, msg_len: 0, payload: <<>>})
        )

      assert <<0x18, 0x00, 0x00, 0x00>> == packet
    end
  end

  # ── Packet Decoding ────────────────────────────────────────────────

  describe "packet decoding" do
    test "decode single-fragment (B|E)" do
      assert {:data, %{beginning: true, ending: true, seq: 0, msg_len: 5, payload: "hello"}} =
               Packet.decode(<<0x18, 0x00, 0x05, 0x00, "hello">>)
    end

    test "decode beginning-only" do
      assert {:data, %{beginning: true, ending: false, seq: 0, msg_len: 100, payload: "abc"}} =
               Packet.decode(<<0x10, 0x00, 100, 0x00, "abc">>)
    end

    test "decode middle fragment" do
      assert {:data, %{beginning: false, ending: false, seq: 1, msg_len: nil, payload: "xyz"}} =
               Packet.decode(<<0x00, 0x01, "xyz">>)
    end

    test "decode ending fragment" do
      assert {:data, %{beginning: false, ending: true, seq: 2, msg_len: nil, payload: "end"}} =
               Packet.decode(<<0x08, 0x02, "end">>)
    end

    test "decode data with ack" do
      assert {:data, %{ack: 5, seq: 3, beginning: true, ending: true}} =
               Packet.decode(<<0x1C, 0x05, 0x03, 0x0A, 0x00, "hi">>)
    end

    test "decode ack-only" do
      assert {:ack_only, 42} = Packet.decode(<<0x04, 42>>)
    end

    test "invalid packet" do
      assert {:error, :invalid_packet} = Packet.decode(<<>>)
    end
  end

  # ── Packet Roundtrip ───────────────────────────────────────────────

  describe "packet encode/decode roundtrip" do
    test "single-fragment roundtrip" do
      fields = %{flags: 0x18, ack: nil, seq: 7, msg_len: 3, payload: "abc"}
      {:data, decoded} = fields |> Packet.encode_data() |> IO.iodata_to_binary() |> Packet.decode()

      assert decoded.seq == 7
      assert decoded.msg_len == 3
      assert decoded.payload == "abc"
      assert decoded.beginning == true
      assert decoded.ending == true
    end

    test "ack-only roundtrip" do
      {:ack_only, 200} = 200 |> Packet.encode_ack() |> IO.iodata_to_binary() |> Packet.decode()
    end
  end

  # ── Fragmentation ──────────────────────────────────────────────────

  describe "fragmentation" do
    test "message smaller than MTU produces one packet" do
      state = BTP.new(mtu: 64)
      {packets, _state} = BTP.fragment(state, "hello")
      assert length(packets) == 1
    end

    test "single packet has B and E flags" do
      state = BTP.new(mtu: 64)
      {[packet], _state} = BTP.fragment(state, "hello")
      {:data, decoded} = Packet.decode(packet)
      assert decoded.beginning == true
      assert decoded.ending == true
    end

    test "single packet carries msg_len" do
      state = BTP.new(mtu: 64)
      {[packet], _state} = BTP.fragment(state, "hello")
      {:data, decoded} = Packet.decode(packet)
      assert decoded.msg_len == 5
    end

    test "message larger than first payload produces two packets" do
      # mtu=10, first payload = 10-4 = 6 bytes, rest payload = 10-2 = 8 bytes
      # 7-byte message: first takes 6, second takes 1
      state = BTP.new(mtu: 10)
      {packets, _state} = BTP.fragment(state, "1234567")
      assert length(packets) == 2
    end

    test "two-packet message: first has B, second has E" do
      state = BTP.new(mtu: 10)
      {[p1, p2], _state} = BTP.fragment(state, "1234567")
      {:data, d1} = Packet.decode(p1)
      {:data, d2} = Packet.decode(p2)
      assert d1.beginning == true
      assert d1.ending == false
      assert d2.beginning == false
      assert d2.ending == true
    end

    test "only first packet carries msg_len" do
      state = BTP.new(mtu: 10)
      {[p1, p2], _state} = BTP.fragment(state, "1234567")
      {:data, d1} = Packet.decode(p1)
      {:data, d2} = Packet.decode(p2)
      assert d1.msg_len == 7
      assert d2.msg_len == nil
    end

    test "sequence numbers increment" do
      state = BTP.new(mtu: 10)
      {[p1, p2], _state} = BTP.fragment(state, "1234567")
      {:data, d1} = Packet.decode(p1)
      {:data, d2} = Packet.decode(p2)
      assert d1.seq == 0
      assert d2.seq == 1
    end

    test "sequence numbers start from state.tx_seq" do
      state = BTP.new(mtu: 10)
      state = %{state | tx_seq: 100}
      {[p1, p2], _state} = BTP.fragment(state, "1234567")
      {:data, d1} = Packet.decode(p1)
      {:data, d2} = Packet.decode(p2)
      assert d1.seq == 100
      assert d2.seq == 101
    end

    test "sequence wraps from 255 to 0" do
      state = %{BTP.new(mtu: 10) | tx_seq: 255}
      {[p1, p2], new_state} = BTP.fragment(state, "1234567")
      {:data, d1} = Packet.decode(p1)
      {:data, d2} = Packet.decode(p2)
      assert d1.seq == 255
      assert d2.seq == 0
      assert new_state.tx_seq == 1
    end

    test "tx_seq updated after fragmentation" do
      state = BTP.new(mtu: 64)
      {_packets, new_state} = BTP.fragment(state, "hello")
      assert new_state.tx_seq == 1
    end

    test "all payload bytes appear exactly once across fragments" do
      message = :binary.copy(<<0xFF>>, 25)
      state = BTP.new(mtu: 10)
      {packets, _state} = BTP.fragment(state, message)

      reassembled =
        packets
        |> Enum.map(fn pkt ->
          {:data, d} = Packet.decode(pkt)
          d.payload
        end)
        |> IO.iodata_to_binary()

      assert reassembled == message
    end

    test "large message (1000 bytes) fragments correctly" do
      message = :binary.copy("x", 1000)
      state = BTP.new(mtu: 64)
      {packets, _state} = BTP.fragment(state, message)

      # First: 64-4=60 bytes, rest: 64-2=62 bytes each
      # Remaining after first: 940. Ceil(940/62) = 16. Total = 17 packets.
      assert length(packets) == 17

      reassembled =
        packets
        |> Enum.map(fn pkt ->
          {:data, d} = Packet.decode(pkt)
          d.payload
        end)
        |> IO.iodata_to_binary()

      assert reassembled == message
    end

    test "empty message produces one packet with B|E" do
      state = BTP.new(mtu: 64)
      {[packet], _state} = BTP.fragment(state, <<>>)
      {:data, decoded} = Packet.decode(packet)
      assert decoded.beginning == true
      assert decoded.ending == true
      assert decoded.msg_len == 0
      assert decoded.payload == <<>>
    end

    test "mtu=23 (minimum BLE 4.0)" do
      # First payload = 23-4 = 19, rest = 23-2 = 21
      message = :binary.copy("a", 50)
      state = BTP.new(mtu: 23)
      {packets, _state} = BTP.fragment(state, message)

      # 19 + 21 = 40. Still need 10 more. So 3 packets.
      assert length(packets) == 3

      reassembled =
        packets
        |> Enum.map(fn pkt ->
          {:data, d} = Packet.decode(pkt)
          d.payload
        end)
        |> IO.iodata_to_binary()

      assert reassembled == message
    end

    test "message exactly equal to first payload size produces one packet" do
      # mtu=10, first payload = 6 bytes
      state = BTP.new(mtu: 10)
      {packets, _state} = BTP.fragment(state, "123456")
      assert length(packets) == 1
    end

    test "message one byte larger than first payload produces two packets" do
      state = BTP.new(mtu: 10)
      {packets, _state} = BTP.fragment(state, "1234567")
      assert length(packets) == 2
    end
  end

  # ── Reassembly ─────────────────────────────────────────────────────

  describe "reassembly" do
    test "single-fragment message reassembles immediately" do
      state = BTP.new(mtu: 64)
      {[packet], _} = BTP.fragment(state, "hello")

      rx_state = BTP.new(mtu: 64)
      assert {:complete, "hello", _new_state} = BTP.receive_segment(rx_state, packet)
    end

    test "two-fragment message reassembles on second segment" do
      state = BTP.new(mtu: 10)
      {[p1, p2], _} = BTP.fragment(state, "1234567")

      rx = BTP.new(mtu: 10)
      assert {:ok, rx} = BTP.receive_segment(rx, p1)
      assert {:complete, "1234567", _rx} = BTP.receive_segment(rx, p2)
    end

    test "three-fragment message" do
      message = :binary.copy("x", 20)
      state = BTP.new(mtu: 10)
      {[p1, p2, p3], _} = BTP.fragment(state, message)

      rx = BTP.new(mtu: 10)
      {:ok, rx} = BTP.receive_segment(rx, p1)
      {:ok, rx} = BTP.receive_segment(rx, p2)
      {:complete, result, _rx} = BTP.receive_segment(rx, p3)
      assert result == message
    end

    test "large message roundtrip through fragment and reassemble" do
      message = :binary.copy("M", 500)
      state = BTP.new(mtu: 64)
      {packets, _} = BTP.fragment(state, message)

      rx = BTP.new(mtu: 64)

      {result, _final_rx} =
        Enum.reduce(packets, {nil, rx}, fn pkt, {_result, rx_state} ->
          case BTP.receive_segment(rx_state, pkt) do
            {:ok, new_rx} -> {nil, new_rx}
            {:complete, msg, new_rx} -> {msg, new_rx}
          end
        end)

      assert result == message
    end

    test "out-of-order sequence returns error" do
      state = BTP.new(mtu: 10)
      {[p1, _p2], _} = BTP.fragment(state, "1234567")

      rx = BTP.new(mtu: 10)
      {:ok, rx} = BTP.receive_segment(rx, p1)

      # Fabricate a packet with wrong sequence number
      bad_packet =
        IO.iodata_to_binary(
          Packet.encode_data(%{flags: 0x08, ack: nil, seq: 99, msg_len: nil, payload: "x"})
        )

      assert {:error, :sequence_gap} = BTP.receive_segment(rx, bad_packet)
    end

    test "continuation without beginning returns error" do
      rx = BTP.new(mtu: 10)

      mid_packet =
        IO.iodata_to_binary(
          Packet.encode_data(%{flags: 0x00, ack: nil, seq: 0, msg_len: nil, payload: "x"})
        )

      assert {:error, :unexpected_continuation} = BTP.receive_segment(rx, mid_packet)
    end

    test "seq wraps: 255 followed by 0" do
      state = %{BTP.new(mtu: 10) | tx_seq: 255}
      {[p1, p2], _} = BTP.fragment(state, "1234567")

      rx = BTP.new(mtu: 10)
      {:ok, rx} = BTP.receive_segment(rx, p1)
      assert {:complete, "1234567", _rx} = BTP.receive_segment(rx, p2)
    end

    test "ack_pending set after receiving data" do
      state = BTP.new(mtu: 64)
      {[packet], _} = BTP.fragment(state, "hello")

      rx = BTP.new(mtu: 64)
      assert rx.ack_pending == false
      {:complete, _msg, new_rx} = BTP.receive_segment(rx, packet)
      assert new_rx.ack_pending == true
    end

    test "ack-only packet" do
      ack_pkt = BTP.encode_ack(42)
      rx = BTP.new()
      assert {:ack_only, 42, _rx} = BTP.receive_segment(rx, ack_pkt)
    end

    test "rx_buffer cleared after complete message" do
      state = BTP.new(mtu: 64)
      {[packet], _} = BTP.fragment(state, "hello")

      rx = BTP.new(mtu: 64)
      {:complete, _msg, new_rx} = BTP.receive_segment(rx, packet)
      assert new_rx.rx_buffer == []
      assert new_rx.rx_message_length == nil
    end

    test "empty message reassembly" do
      state = BTP.new(mtu: 64)
      {[packet], _} = BTP.fragment(state, <<>>)

      rx = BTP.new(mtu: 64)
      assert {:complete, <<>>, _rx} = BTP.receive_segment(rx, packet)
    end
  end

  # ── Handshake ──────────────────────────────────────────────────────

  describe "handshake" do
    test "handshake request encoding" do
      binary = BTP.handshake_request()
      assert {:request, params} = BTP.decode_handshake(binary)
      assert params.mtu == 247
      assert params.window_size == 6
    end

    test "handshake request with custom options" do
      binary = BTP.handshake_request(mtu: 128, window_size: 3)
      assert {:request, params} = BTP.decode_handshake(binary)
      assert params.mtu == 128
      assert params.window_size == 3
    end

    test "handshake response encoding" do
      binary = BTP.handshake_response(4, mtu: 200, window_size: 4)
      assert {:response, params} = BTP.decode_handshake(binary)
      assert params.selected_version == 4
      assert params.mtu == 200
      assert params.window_size == 4
    end

    test "handshake response with defaults" do
      binary = BTP.handshake_response(4)
      assert {:response, params} = BTP.decode_handshake(binary)
      assert params.mtu == 247
      assert params.window_size == 6
    end

    test "decode_handshake rejects non-handshake" do
      assert {:error, :not_a_handshake} = BTP.decode_handshake(<<0x18, 0x00, 0x05, 0x00, "x">>)
    end

    test "handshake request binary format" do
      binary = BTP.handshake_request(versions: <<1, 2, 3, 4>>, mtu: 247, window_size: 6)
      # flags=0x03 (H|M), opcode=0x6C, versions, mtu=247 LE (0xF7, 0x00), ws=6
      assert <<0x03, 0x6C, 1, 2, 3, 4, 0xF7, 0x00, 6>> == binary
    end

    test "handshake response binary format" do
      binary = BTP.handshake_response(4, mtu: 247, window_size: 6)
      # flags=0x03, opcode=0x6C, version=4 LE (0x04, 0x00), mtu=247 LE, ws=6
      assert <<0x03, 0x6C, 0x04, 0x00, 0xF7, 0x00, 6>> == binary
    end
  end

  # ── encode_ack ─────────────────────────────────────────────────────

  describe "encode_ack" do
    test "encodes ack packet" do
      assert <<0x04, 0>> == BTP.encode_ack(0)
    end

    test "ack at boundary" do
      assert <<0x04, 255>> == BTP.encode_ack(255)
    end

    test "ack roundtrip through receive_segment" do
      pkt = BTP.encode_ack(127)
      rx = BTP.new()
      assert {:ack_only, 127, _rx} = BTP.receive_segment(rx, pkt)
    end
  end

  # ── BTP State ──────────────────────────────────────────────────────

  describe "state" do
    test "new/0 defaults" do
      state = BTP.new()
      assert state.mtu == 247
      assert state.window_size == 6
      assert state.tx_seq == 0
      assert state.rx_seq == nil
      assert state.rx_buffer == []
      assert state.ack_pending == false
    end

    test "new/1 respects custom mtu" do
      state = BTP.new(mtu: 64)
      assert state.mtu == 64
    end

    test "new/1 respects custom window_size" do
      state = BTP.new(window_size: 3)
      assert state.window_size == 3
    end

    test "tx_seq wraps across multiple fragment calls" do
      state = %{BTP.new(mtu: 10) | tx_seq: 254}
      {_pkts, state} = BTP.fragment(state, "1234567")
      # 2 packets: seq 254, 255 -> tx_seq now 0
      assert state.tx_seq == 0

      {_pkts, state} = BTP.fragment(state, "1234567")
      # 2 more packets: seq 0, 1 -> tx_seq now 2
      assert state.tx_seq == 2
    end
  end
end
