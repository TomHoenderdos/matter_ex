defmodule MatterEx.MDNS.DNSTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias MatterEx.MDNS.DNS

  # ── Name Encoding ──────────────────────────────────────────────

  describe "name encoding" do
    test "encodes single-label name" do
      assert DNS.encode_name("local") == <<5, "local", 0>>
    end

    test "encodes multi-label name" do
      encoded = DNS.encode_name("_matterc._udp.local")
      assert encoded == <<8, "_matterc", 4, "_udp", 5, "local", 0>>
    end

    test "encodes service instance name" do
      encoded = DNS.encode_name("MATTER-0F00._matterc._udp.local")

      assert encoded == <<
        11, "MATTER-0F00",
        8, "_matterc",
        4, "_udp",
        5, "local",
        0
      >>
    end
  end

  # ── Name Decoding ──────────────────────────────────────────────

  describe "name decoding" do
    test "decodes simple name" do
      data = <<5, "local", 0>>
      {name, consumed} = DNS.decode_name(data, 0)
      assert name == "local"
      assert consumed == 7
    end

    test "decodes multi-label name" do
      data = <<8, "_matterc", 4, "_udp", 5, "local", 0>>
      {name, consumed} = DNS.decode_name(data, 0)
      assert name == "_matterc._udp.local"
      assert consumed == byte_size(data)
    end

    test "decodes name with pointer compression" do
      # Build a message where a name at offset 20 points back to offset 0
      name_at_0 = <<5, "local", 0>>
      padding = :binary.copy(<<0>>, 13)  # fill to offset 20
      pointer = <<0xC0, 0x00>>  # pointer to offset 0

      message = name_at_0 <> padding <> pointer

      {name, consumed} = DNS.decode_name(message, 20)
      assert name == "local"
      assert consumed == 2  # only the pointer bytes consumed
    end

    test "round-trip encode/decode" do
      original = "_matterc._udp.local"
      encoded = DNS.encode_name(original)
      {decoded, _consumed} = DNS.decode_name(encoded, 0)
      assert decoded == original
    end
  end

  # ── TXT Encoding/Decoding ─────────────────────────────────────

  describe "TXT encoding" do
    test "encodes key=value pairs" do
      encoded = DNS.encode_txt(["D=3840", "CM=1"])
      assert encoded == <<6, "D=3840", 4, "CM=1">>
    end

    test "encodes empty list as single zero byte" do
      assert DNS.encode_txt([]) == <<0>>
    end

    test "round-trip encode/decode" do
      original = ["D=3840", "VP=65521+32769", "CM=1", "DT=256"]
      encoded = DNS.encode_txt(original)
      decoded = DNS.decode_txt(encoded)
      assert decoded == original
    end
  end

  # ── Record Data Encoding ───────────────────────────────────────

  describe "record data encoding" do
    test "A record" do
      assert DNS.encode_rdata(:a, {192, 168, 1, 100}) == <<192, 168, 1, 100>>
    end

    test "AAAA record from binary" do
      addr = <<0xFE, 0x80, 0::88, 0x01, 0::16>>
      assert DNS.encode_rdata(:aaaa, addr) == addr
    end

    test "AAAA record from tuple" do
      addr = {0xFE80, 0, 0, 0, 0, 0, 0, 1}
      encoded = DNS.encode_rdata(:aaaa, addr)
      assert encoded == <<0xFE80::16, 0::16, 0::16, 0::16, 0::16, 0::16, 0::16, 1::16>>
    end

    test "PTR record" do
      encoded = DNS.encode_rdata(:ptr, "instance._tcp.local")
      expected = DNS.encode_name("instance._tcp.local")
      assert encoded == expected
    end

    test "SRV record" do
      encoded = DNS.encode_rdata(:srv, {0, 0, 5540, "host.local"})
      expected = <<0::16, 0::16, 5540::16>> <> DNS.encode_name("host.local")
      assert encoded == expected
    end

    test "TXT record" do
      encoded = DNS.encode_rdata(:txt, ["D=3840"])
      assert encoded == <<6, "D=3840">>
    end
  end

  # ── Message Encoding ───────────────────────────────────────────

  describe "message encoding" do
    test "encodes query with single question" do
      msg = %{
        id: 0,
        qr: :query,
        aa: false,
        questions: [%{name: "_matterc._udp.local", type: :ptr, class: :in}],
        answers: [],
        authority: [],
        additional: []
      }

      binary = DNS.encode_message(msg)

      # Header: 12 bytes
      <<id::16, flags::16, qdcount::16, ancount::16, _nscount::16, _arcount::16, _body::binary>> = binary
      assert id == 0
      assert qdcount == 1
      assert ancount == 0

      # QR bit should be 0 (query)
      assert (flags >>> 15) == 0
    end

    test "encodes response with answer" do
      msg = %{
        id: 0,
        qr: :response,
        aa: true,
        questions: [],
        answers: [
          %{name: "_matterc._udp.local", type: :ptr, class: :in, ttl: 120,
            data: "MATTER-0F00._matterc._udp.local"}
        ]
      }

      binary = DNS.encode_message(msg)

      <<_id::16, flags::16, qdcount::16, ancount::16, _rest::binary>> = binary
      # QR=1, AA=1
      assert (flags >>> 15) == 1
      assert (flags >>> 10 &&& 1) == 1
      assert qdcount == 0
      assert ancount == 1
    end

    test "encodes response with cache-flush bit" do
      msg = %{
        id: 0,
        qr: :response,
        aa: true,
        questions: [],
        answers: [
          %{name: "host.local", type: :a, class: :in, cache_flush: true,
            ttl: 120, data: {192, 168, 1, 100}}
        ]
      }

      binary = DNS.encode_message(msg)
      {:ok, decoded} = DNS.decode_message(binary)
      [record] = decoded.answers
      assert record.cache_flush == true
    end
  end

  # ── Message Decoding ───────────────────────────────────────────

  describe "message decoding" do
    test "decodes query" do
      msg = %{
        id: 0, qr: :query, aa: false,
        questions: [%{name: "_matterc._udp.local", type: :ptr, class: :in}],
        answers: [], authority: [], additional: []
      }

      binary = DNS.encode_message(msg)
      {:ok, decoded} = DNS.decode_message(binary)

      assert decoded.qr == :query
      assert decoded.id == 0
      assert length(decoded.questions) == 1
      [q] = decoded.questions
      assert q.name == "_matterc._udp.local"
      assert q.type == :ptr
    end

    test "decodes response with A record" do
      msg = %{
        id: 0, qr: :response, aa: true,
        questions: [],
        answers: [
          %{name: "host.local", type: :a, class: :in, ttl: 120, data: {192, 168, 1, 100}}
        ]
      }

      binary = DNS.encode_message(msg)
      {:ok, decoded} = DNS.decode_message(binary)

      assert decoded.qr == :response
      assert decoded.aa == true
      [record] = decoded.answers
      assert record.name == "host.local"
      assert record.type == :a
      assert record.ttl == 120
      assert record.data == {192, 168, 1, 100}
    end

    test "decodes response with SRV record" do
      msg = %{
        id: 0, qr: :response, aa: true,
        questions: [],
        answers: [
          %{name: "instance._tcp.local", type: :srv, class: :in, ttl: 120,
            data: {0, 0, 5540, "host.local"}}
        ]
      }

      binary = DNS.encode_message(msg)
      {:ok, decoded} = DNS.decode_message(binary)

      [record] = decoded.answers
      assert record.type == :srv
      {priority, weight, port, target} = record.data
      assert priority == 0
      assert weight == 0
      assert port == 5540
      assert target == "host.local"
    end

    test "decodes response with TXT record" do
      msg = %{
        id: 0, qr: :response, aa: true,
        questions: [],
        answers: [
          %{name: "instance._udp.local", type: :txt, class: :in, ttl: 4500,
            data: ["D=3840", "VP=65521+32769", "CM=1"]}
        ]
      }

      binary = DNS.encode_message(msg)
      {:ok, decoded} = DNS.decode_message(binary)

      [record] = decoded.answers
      assert record.type == :txt
      assert record.data == ["D=3840", "VP=65521+32769", "CM=1"]
    end

    test "decodes response with PTR record" do
      msg = %{
        id: 0, qr: :response, aa: true,
        questions: [],
        answers: [
          %{name: "_matterc._udp.local", type: :ptr, class: :in, ttl: 4500,
            data: "MATTER-0F00._matterc._udp.local"}
        ]
      }

      binary = DNS.encode_message(msg)
      {:ok, decoded} = DNS.decode_message(binary)

      [record] = decoded.answers
      assert record.type == :ptr
      assert record.data == "MATTER-0F00._matterc._udp.local"
    end

    test "round-trip full response with multiple records" do
      msg = %{
        id: 0, qr: :response, aa: true,
        questions: [],
        answers: [
          %{name: "_matterc._udp.local", type: :ptr, class: :in, ttl: 4500,
            data: "MATTER-0F00._matterc._udp.local"},
          %{name: "MATTER-0F00._matterc._udp.local", type: :srv, class: :in,
            cache_flush: true, ttl: 120, data: {0, 0, 5540, "matter_ex.local"}},
          %{name: "MATTER-0F00._matterc._udp.local", type: :txt, class: :in,
            cache_flush: true, ttl: 4500, data: ["D=3840", "CM=1"]},
          %{name: "matter_ex.local", type: :a, class: :in,
            cache_flush: true, ttl: 120, data: {192, 168, 1, 100}}
        ]
      }

      binary = DNS.encode_message(msg)
      {:ok, decoded} = DNS.decode_message(binary)

      assert decoded.qr == :response
      assert decoded.aa == true
      assert length(decoded.answers) == 4

      [ptr, srv, txt, a] = decoded.answers
      assert ptr.type == :ptr
      assert srv.type == :srv
      assert txt.type == :txt
      assert a.type == :a
      assert a.data == {192, 168, 1, 100}
    end

    test "returns error for invalid message" do
      assert {:error, :too_short} = DNS.decode_message(<<1, 2, 3>>)
    end
  end
end
