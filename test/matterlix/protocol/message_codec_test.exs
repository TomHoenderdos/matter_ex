defmodule Matterlix.Protocol.MessageCodecTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Matterlix.Protocol.MessageCodec
  alias Matterlix.Protocol.MessageCodec.{Header, ProtoHeader}

  # ── Header encode/decode ────────────────────────────────────────

  describe "Header encode/decode" do
    test "minimal header (no src, no dest)" do
      h = %Header{session_id: 0, message_counter: 1}
      encoded = IO.iodata_to_binary(Header.encode(h))

      # msg_flags=0x00 (version=0, no S, DSIZ=00), session=0x0000, sec_flags=0x00, counter=1
      assert <<0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00>> = encoded

      {:ok, decoded, rest} = Header.decode(encoded)
      assert rest == <<>>
      assert decoded.session_id == 0
      assert decoded.message_counter == 1
      assert decoded.source_node_id == nil
      assert decoded.dest_node_id == nil
      assert decoded.dest_group_id == nil
    end

    test "header with source node ID" do
      h = %Header{session_id: 0x0100, message_counter: 42, source_node_id: 0x0102030405060708}
      encoded = IO.iodata_to_binary(Header.encode(h))

      # msg_flags: S bit set = 0x04
      assert <<0x04, _::binary>> = encoded

      {:ok, decoded, <<>>} = Header.decode(encoded)
      assert decoded.source_node_id == 0x0102030405060708
      assert decoded.session_id == 0x0100
      assert decoded.message_counter == 42
    end

    test "header with dest node ID (DSIZ=01)" do
      h = %Header{message_counter: 1, dest_node_id: 0xAABBCCDDEEFF0011}
      encoded = IO.iodata_to_binary(Header.encode(h))

      # DSIZ = 01 in bits 1:0
      <<msg_flags, _::binary>> = encoded
      assert (msg_flags &&& 0x03) == 0x01

      {:ok, decoded, <<>>} = Header.decode(encoded)
      assert decoded.dest_node_id == 0xAABBCCDDEEFF0011
      assert decoded.dest_group_id == nil
    end

    test "header with dest group ID (DSIZ=10)" do
      h = %Header{message_counter: 1, dest_group_id: 0x1234}
      encoded = IO.iodata_to_binary(Header.encode(h))

      <<msg_flags, _::binary>> = encoded
      assert (msg_flags &&& 0x03) == 0x02

      {:ok, decoded, <<>>} = Header.decode(encoded)
      assert decoded.dest_group_id == 0x1234
      assert decoded.dest_node_id == nil
    end

    test "header with src + dest node IDs" do
      h = %Header{
        message_counter: 100,
        source_node_id: 1,
        dest_node_id: 2
      }

      encoded = IO.iodata_to_binary(Header.encode(h))
      # S=1, DSIZ=01 => msg_flags bits: 0x04 | 0x01 = 0x05
      <<0x05, _::binary>> = encoded
      # 8 (base) + 8 (src) + 8 (dest) = 24 bytes
      assert byte_size(encoded) == 24

      {:ok, decoded, <<>>} = Header.decode(encoded)
      assert decoded.source_node_id == 1
      assert decoded.dest_node_id == 2
    end

    test "security flags: privacy and control" do
      h = %Header{message_counter: 1, privacy: true, control_message: true}
      encoded = IO.iodata_to_binary(Header.encode(h))

      {:ok, decoded, <<>>} = Header.decode(encoded)
      assert decoded.privacy == true
      assert decoded.control_message == true
      # P=0x80, C=0x40 => 0xC0
      assert (decoded.security_flags &&& 0xC0) == 0xC0
    end

    test "security flags: group session type" do
      h = %Header{message_counter: 1, session_type: :group}
      encoded = IO.iodata_to_binary(Header.encode(h))

      {:ok, decoded, <<>>} = Header.decode(encoded)
      assert decoded.session_type == :group
    end

    test "message counter little-endian encoding" do
      h = %Header{message_counter: 0x04030201}
      encoded = IO.iodata_to_binary(Header.encode(h))

      # Counter bytes at offset 4-7 (after flags, session_id, sec_flags)
      <<_::binary-4, 0x01, 0x02, 0x03, 0x04>> = encoded
    end

    test "session ID little-endian encoding" do
      h = %Header{session_id: 0x0201, message_counter: 0}
      encoded = IO.iodata_to_binary(Header.encode(h))
      <<_flags, 0x01, 0x02, _::binary>> = encoded
    end

    test "preserves trailing data as rest" do
      h = %Header{message_counter: 1}
      encoded = IO.iodata_to_binary(Header.encode(h))
      with_extra = encoded <> <<0xDE, 0xAD>>

      {:ok, _decoded, rest} = Header.decode(with_extra)
      assert rest == <<0xDE, 0xAD>>
    end

    test "truncated header returns error" do
      assert {:error, :truncated_header} = Header.decode(<<0x00, 0x01>>)
      assert {:error, :truncated_header} = Header.decode(<<>>)
    end

    test "truncated source node ID returns error" do
      # S flag set but not enough bytes for 8-byte source ID
      assert {:error, :truncated_header} =
               Header.decode(<<0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xAA>>)
    end

    test "encode/decode roundtrip with all fields" do
      h = %Header{
        version: 0,
        session_id: 0xBEEF,
        message_counter: 0xDEADBEEF,
        source_node_id: 0x0102030405060708,
        dest_node_id: 0x1112131415161718,
        session_type: :unicast,
        privacy: true,
        control_message: true
      }

      encoded = IO.iodata_to_binary(Header.encode(h))
      {:ok, decoded, <<>>} = Header.decode(encoded)

      assert decoded.version == 0
      assert decoded.session_id == 0xBEEF
      assert decoded.message_counter == 0xDEADBEEF
      assert decoded.source_node_id == 0x0102030405060708
      assert decoded.dest_node_id == 0x1112131415161718
      assert decoded.privacy == true
      assert decoded.control_message == true
    end
  end

  # ── ProtoHeader encode/decode ───────────────────────────────────

  describe "ProtoHeader encode/decode" do
    test "minimal proto header (no ack, no vendor)" do
      ph = %ProtoHeader{opcode: 0x02, exchange_id: 1, protocol_id: 0x0001}
      encoded = IO.iodata_to_binary(ProtoHeader.encode(ph))

      # flags=0x00, opcode=0x02, exch_id=0x0001, proto_id=0x0001 => 6 bytes
      assert byte_size(encoded) == 6

      {:ok, decoded} = ProtoHeader.decode(encoded)
      assert decoded.opcode == 0x02
      assert decoded.exchange_id == 1
      assert decoded.protocol_id == 0x0001
      assert decoded.initiator == false
      assert decoded.needs_ack == false
      assert decoded.ack_counter == nil
      assert decoded.vendor_id == nil
      assert decoded.payload == <<>>
    end

    test "proto header with ack counter" do
      ph = %ProtoHeader{opcode: 0x05, exchange_id: 42, protocol_id: 1, ack_counter: 100}
      encoded = IO.iodata_to_binary(ProtoHeader.encode(ph))

      {:ok, decoded} = ProtoHeader.decode(encoded)
      assert decoded.ack_counter == 100
      # A flag should be set
      <<flags, _::binary>> = encoded
      assert (flags &&& 0x02) != 0
    end

    test "proto header with vendor ID" do
      ph = %ProtoHeader{opcode: 0x01, exchange_id: 1, protocol_id: 0x0042, vendor_id: 0xFFF1}
      encoded = IO.iodata_to_binary(ProtoHeader.encode(ph))

      {:ok, decoded} = ProtoHeader.decode(encoded)
      assert decoded.vendor_id == 0xFFF1
      assert decoded.protocol_id == 0x0042
    end

    test "initiator and needs_ack flags" do
      ph = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: 0x20,
        exchange_id: 5,
        protocol_id: 0
      }

      encoded = IO.iodata_to_binary(ProtoHeader.encode(ph))
      {:ok, decoded} = ProtoHeader.decode(encoded)
      assert decoded.initiator == true
      assert decoded.needs_ack == true
    end

    test "payload preserved" do
      payload = <<0xDE, 0xAD, 0xBE, 0xEF>>

      ph = %ProtoHeader{opcode: 0x02, exchange_id: 1, protocol_id: 1, payload: payload}
      encoded = IO.iodata_to_binary(ProtoHeader.encode(ph))

      {:ok, decoded} = ProtoHeader.decode(encoded)
      assert decoded.payload == payload
    end

    test "truncated proto header returns error" do
      assert {:error, :truncated_proto_header} = ProtoHeader.decode(<<0x00, 0x01>>)
      assert {:error, :truncated_proto_header} = ProtoHeader.decode(<<>>)
    end

    test "truncated vendor ID returns error" do
      # V flag set (0x10) but only 1 byte after exchange_id
      assert {:error, :truncated_proto_header} =
               ProtoHeader.decode(<<0x10, 0x02, 0x01, 0x00, 0xAA>>)
    end

    test "encode/decode roundtrip with all fields" do
      ph = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        ack_counter: 0xCAFE,
        vendor_id: 0xFFF1,
        opcode: 0x08,
        exchange_id: 0x1234,
        protocol_id: 0x0001,
        payload: <<"hello">>
      }

      encoded = IO.iodata_to_binary(ProtoHeader.encode(ph))
      {:ok, decoded} = ProtoHeader.decode(encoded)

      assert decoded.initiator == true
      assert decoded.needs_ack == true
      assert decoded.ack_counter == 0xCAFE
      assert decoded.vendor_id == 0xFFF1
      assert decoded.opcode == 0x08
      assert decoded.exchange_id == 0x1234
      assert decoded.protocol_id == 0x0001
      assert decoded.payload == "hello"
    end
  end

  # ── MessageCodec plaintext ──────────────────────────────────────

  describe "plaintext encode/decode" do
    test "roundtrip minimal message" do
      header = %Header{session_id: 0, message_counter: 1}
      proto = %ProtoHeader{opcode: 0x20, exchange_id: 1, protocol_id: 0}

      frame = IO.iodata_to_binary(MessageCodec.encode(header, proto))
      {:ok, decoded} = MessageCodec.decode(frame)

      assert decoded.header.session_id == 0
      assert decoded.header.message_counter == 1
      assert decoded.proto.opcode == 0x20
      assert decoded.proto.exchange_id == 1
      assert decoded.proto.protocol_id == 0
    end

    test "roundtrip with all optional fields" do
      header = %Header{
        session_id: 0x1234,
        message_counter: 0xABCD,
        source_node_id: 0x0102030405060708,
        dest_node_id: 0x1112131415161718,
        control_message: true
      }

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        ack_counter: 42,
        opcode: 0x02,
        exchange_id: 100,
        protocol_id: 0x0001,
        payload: :crypto.strong_rand_bytes(50)
      }

      frame = IO.iodata_to_binary(MessageCodec.encode(header, proto))
      {:ok, decoded} = MessageCodec.decode(frame)

      assert decoded.header.session_id == 0x1234
      assert decoded.header.source_node_id == 0x0102030405060708
      assert decoded.header.dest_node_id == 0x1112131415161718
      assert decoded.header.control_message == true
      assert decoded.proto.initiator == true
      assert decoded.proto.ack_counter == 42
      assert decoded.proto.payload == proto.payload
    end

    test "invalid binary returns error" do
      assert {:error, :truncated_header} = MessageCodec.decode(<<0x00>>)
    end
  end

  # ── MessageCodec encrypted ─────────────────────────────────────

  describe "encrypted encode/decode" do
    setup do
      key = :crypto.strong_rand_bytes(16)
      %{key: key}
    end

    test "roundtrip with known key and nonce", %{key: key} do
      header = %Header{session_id: 1, message_counter: 42, source_node_id: 0x1234}

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: 0x05,
        exchange_id: 7,
        protocol_id: 0x0001,
        payload: <<"test payload">>
      }

      nonce = MessageCodec.build_nonce(header.security_flags, header.message_counter, header.source_node_id)
      frame = IO.iodata_to_binary(MessageCodec.encode_encrypted(header, proto, key, nonce))

      {:ok, decoded} = MessageCodec.decode_encrypted(frame, key, nonce)
      assert decoded.header.session_id == 1
      assert decoded.header.message_counter == 42
      assert decoded.proto.opcode == 0x05
      assert decoded.proto.payload == "test payload"
    end

    test "tampered ciphertext returns :authentication_failed", %{key: key} do
      header = %Header{session_id: 1, message_counter: 1}
      proto = %ProtoHeader{opcode: 0x02, exchange_id: 1, protocol_id: 1, payload: <<"data">>}
      nonce = MessageCodec.build_nonce(0, 1)

      frame = IO.iodata_to_binary(MessageCodec.encode_encrypted(header, proto, key, nonce))

      # Tamper with a ciphertext byte (after 8-byte header, before last 16-byte MIC)
      header_size = 8
      <<hdr::binary-size(header_size), ct_byte, rest::binary>> = frame
      tampered = <<hdr::binary, ct_byte + 1, rest::binary>>

      assert {:error, :authentication_failed} = MessageCodec.decode_encrypted(tampered, key, nonce)
    end

    test "tampered header (AAD) returns :authentication_failed", %{key: key} do
      header = %Header{session_id: 1, message_counter: 1}
      proto = %ProtoHeader{opcode: 0x02, exchange_id: 1, protocol_id: 1}
      nonce = MessageCodec.build_nonce(0, 1)

      frame = IO.iodata_to_binary(MessageCodec.encode_encrypted(header, proto, key, nonce))

      # Tamper with session ID byte (byte 1)
      <<flags, session_lo, rest::binary>> = frame
      tampered = <<flags, session_lo + 1, rest::binary>>

      assert {:error, :authentication_failed} = MessageCodec.decode_encrypted(tampered, key, nonce)
    end

    test "tampered MIC returns :authentication_failed", %{key: key} do
      header = %Header{session_id: 1, message_counter: 1}
      proto = %ProtoHeader{opcode: 0x02, exchange_id: 1, protocol_id: 1}
      nonce = MessageCodec.build_nonce(0, 1)

      frame = IO.iodata_to_binary(MessageCodec.encode_encrypted(header, proto, key, nonce))

      # Flip last byte (part of MIC)
      size = byte_size(frame)
      <<prefix::binary-size(size - 1), last_byte>> = frame
      tampered = <<prefix::binary, last_byte + 1>>

      assert {:error, :authentication_failed} = MessageCodec.decode_encrypted(tampered, key, nonce)
    end

    test "truncated MIC returns error", %{key: key} do
      header = %Header{session_id: 1, message_counter: 1}
      nonce = MessageCodec.build_nonce(0, 1)

      # Just the 8-byte header + a few bytes (less than 16-byte MIC)
      short = IO.iodata_to_binary(Header.encode(header)) <> <<0x01, 0x02>>

      assert {:error, :truncated_mic} = MessageCodec.decode_encrypted(short, key, nonce)
    end

    test "wrong key returns :authentication_failed", %{key: key} do
      header = %Header{session_id: 1, message_counter: 1}
      proto = %ProtoHeader{opcode: 0x02, exchange_id: 1, protocol_id: 1}
      nonce = MessageCodec.build_nonce(0, 1)

      frame = IO.iodata_to_binary(MessageCodec.encode_encrypted(header, proto, key, nonce))

      wrong_key = :crypto.strong_rand_bytes(16)
      assert {:error, :authentication_failed} = MessageCodec.decode_encrypted(frame, wrong_key, nonce)
    end
  end

  # ── build_nonce ─────────────────────────────────────────────────

  describe "build_nonce/3" do
    test "length is 13 bytes" do
      nonce = MessageCodec.build_nonce(0x00, 0, 0)
      assert byte_size(nonce) == 13
    end

    test "structure: flags || counter LE || node_id LE" do
      nonce = MessageCodec.build_nonce(0xAB, 0x04030201, 0x0807060504030201)

      assert <<0xAB, 0x01, 0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
               0x08>> = nonce
    end

    test "PASE nonce (node_id defaults to 0)" do
      nonce = MessageCodec.build_nonce(0x00, 42)
      assert <<0x00, 42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>> = nonce
    end
  end
end
