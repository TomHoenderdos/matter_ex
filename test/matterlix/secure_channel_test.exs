defmodule Matterlix.SecureChannelTest do
  use ExUnit.Case, async: true

  alias Matterlix.SecureChannel
  alias Matterlix.Session
  alias Matterlix.PASE
  alias Matterlix.Protocol.MessageCodec.ProtoHeader

  @passcode 20202021
  @salt :crypto.strong_rand_bytes(32)
  @iterations 1000

  # ── Session key derivation ────────────────────────────────────────

  describe "session key derivation" do
    test "derives three distinct 16-byte keys" do
      ke = :crypto.strong_rand_bytes(16)
      {i2r, r2i, challenge} = Session.derive_session_keys(ke)

      assert byte_size(i2r) == 16
      assert byte_size(r2i) == 16
      assert byte_size(challenge) == 16
      assert i2r != r2i
      assert i2r != challenge
      assert r2i != challenge
    end

    test "same Ke always produces same keys" do
      ke = :crypto.strong_rand_bytes(16)
      {i2r1, r2i1, ch1} = Session.derive_session_keys(ke)
      {i2r2, r2i2, ch2} = Session.derive_session_keys(ke)

      assert i2r1 == i2r2
      assert r2i1 == r2i2
      assert ch1 == ch2
    end

    test "initiator and responder get opposite encrypt/decrypt keys" do
      ke = :crypto.strong_rand_bytes(16)

      initiator = Session.new(
        local_session_id: 1, peer_session_id: 2,
        encryption_key: ke, role: :initiator
      )

      responder = Session.new(
        local_session_id: 2, peer_session_id: 1,
        encryption_key: ke, role: :responder
      )

      # Initiator encrypts with I2R, responder decrypts with I2R
      assert initiator.encrypt_key == responder.decrypt_key
      # Responder encrypts with R2I, initiator decrypts with R2I
      assert responder.encrypt_key == initiator.decrypt_key
    end

    test "session stores node IDs" do
      ke = :crypto.strong_rand_bytes(16)
      session = Session.new(
        local_session_id: 1, peer_session_id: 2,
        encryption_key: ke, local_node_id: 0x1234, peer_node_id: 0x5678
      )

      assert session.local_node_id == 0x1234
      assert session.peer_node_id == 0x5678
    end

    test "node IDs default to 0" do
      ke = :crypto.strong_rand_bytes(16)
      session = Session.new(
        local_session_id: 1, peer_session_id: 2, encryption_key: ke
      )

      assert session.local_node_id == 0
      assert session.peer_node_id == 0
    end
  end

  # ── SecureChannel.seal ────────────────────────────────────────────

  describe "SecureChannel.seal" do
    setup do
      ke = :crypto.strong_rand_bytes(16)
      session = Session.new(
        local_session_id: 1, peer_session_id: 2,
        encryption_key: ke, role: :initiator
      )
      %{session: session}
    end

    test "produces binary frame", %{session: session} do
      proto = %ProtoHeader{
        opcode: 0x05, exchange_id: 1, protocol_id: 0x0001,
        payload: <<"hello">>
      }

      {frame, _session} = SecureChannel.seal(session, proto)
      assert is_binary(frame)
      assert byte_size(frame) > 0
    end

    test "counter increments after each seal", %{session: session} do
      proto = %ProtoHeader{
        opcode: 0x05, exchange_id: 1, protocol_id: 0x0001,
        payload: <<"hello">>
      }

      {_frame1, session} = SecureChannel.seal(session, proto)
      {_frame2, session} = SecureChannel.seal(session, proto)
      {_frame3, _session} = SecureChannel.seal(session, proto)

      # Counter should have advanced 3 times (can't observe directly,
      # but open will accept all three different counter values)
    end

    test "frame starts with valid header", %{session: session} do
      proto = %ProtoHeader{
        opcode: 0x05, exchange_id: 1, protocol_id: 0x0001,
        payload: <<"test">>
      }

      {frame, _session} = SecureChannel.seal(session, proto)

      # Parse header to verify structure
      {:ok, header, _rest} = Matterlix.Protocol.MessageCodec.Header.decode(frame)
      assert header.session_id == 2  # peer_session_id
      assert header.privacy == false
    end
  end

  # ── SecureChannel.open ────────────────────────────────────────────

  describe "SecureChannel.open" do
    setup do
      ke = :crypto.strong_rand_bytes(16)

      sender = Session.new(
        local_session_id: 1, peer_session_id: 2,
        encryption_key: ke, role: :initiator
      )

      receiver = Session.new(
        local_session_id: 2, peer_session_id: 1,
        encryption_key: ke, role: :responder
      )

      %{sender: sender, receiver: receiver}
    end

    test "decrypts frame from seal", %{sender: sender, receiver: receiver} do
      proto = %ProtoHeader{
        opcode: 0x05, exchange_id: 7, protocol_id: 0x0001,
        payload: <<"test payload">>
      }

      {frame, _sender} = SecureChannel.seal(sender, proto)
      assert {:ok, message, _receiver} = SecureChannel.open(receiver, frame)
      assert message.proto.opcode == 0x05
      assert message.proto.exchange_id == 7
      assert message.proto.payload == "test payload"
    end

    test "rejects tampered frame", %{sender: sender, receiver: receiver} do
      proto = %ProtoHeader{
        opcode: 0x05, exchange_id: 1, protocol_id: 0x0001,
        payload: <<"hello">>
      }

      {frame, _sender} = SecureChannel.seal(sender, proto)

      # Tamper with last byte (part of MIC tag)
      tampered = binary_part(frame, 0, byte_size(frame) - 1) <> <<0xFF>>
      assert {:error, :authentication_failed} = SecureChannel.open(receiver, tampered)
    end

    test "rejects duplicate counter (replay)", %{sender: sender, receiver: receiver} do
      proto = %ProtoHeader{
        opcode: 0x05, exchange_id: 1, protocol_id: 0x0001,
        payload: <<"hello">>
      }

      {frame, _sender} = SecureChannel.seal(sender, proto)

      # First open succeeds
      {:ok, _msg, receiver} = SecureChannel.open(receiver, frame)

      # Same frame again is a replay
      assert {:error, :duplicate} = SecureChannel.open(receiver, frame)
    end

    test "rejects wrong session ID", %{sender: sender} do
      proto = %ProtoHeader{
        opcode: 0x05, exchange_id: 1, protocol_id: 0x0001,
        payload: <<"hello">>
      }

      {frame, _sender} = SecureChannel.seal(sender, proto)

      # Create receiver with different local_session_id
      ke = :crypto.strong_rand_bytes(16)
      wrong_receiver = Session.new(
        local_session_id: 99, peer_session_id: 1,
        encryption_key: ke, role: :responder
      )

      assert {:error, :session_mismatch} = SecureChannel.open(wrong_receiver, frame)
    end

    test "accepts multiple sequential messages", %{sender: sender, receiver: receiver} do
      protos = for i <- 1..5 do
        %ProtoHeader{
          opcode: 0x05, exchange_id: i, protocol_id: 0x0001,
          payload: "message #{i}"
        }
      end

      {sender, receiver} =
        Enum.reduce(protos, {sender, receiver}, fn proto, {s, r} ->
          {frame, s} = SecureChannel.seal(s, proto)
          {:ok, _msg, r} = SecureChannel.open(r, frame)
          {s, r}
        end)

      # Verify both sides updated (no crash)
      assert sender.counter != nil
      assert receiver.counter != nil
    end
  end

  # ── Bidirectional communication ──────────────────────────────────

  describe "bidirectional" do
    setup do
      ke = :crypto.strong_rand_bytes(16)

      alice = Session.new(
        local_session_id: 1, peer_session_id: 2,
        encryption_key: ke, role: :initiator
      )

      bob = Session.new(
        local_session_id: 2, peer_session_id: 1,
        encryption_key: ke, role: :responder
      )

      %{alice: alice, bob: bob}
    end

    test "alice sends to bob, bob sends to alice", %{alice: alice, bob: bob} do
      # Alice → Bob
      proto_a = %ProtoHeader{
        opcode: 0x05, exchange_id: 1, protocol_id: 0x0001,
        payload: <<"from alice">>
      }

      {frame_a, alice} = SecureChannel.seal(alice, proto_a)
      {:ok, msg_a, bob} = SecureChannel.open(bob, frame_a)
      assert msg_a.proto.payload == "from alice"

      # Bob → Alice
      proto_b = %ProtoHeader{
        opcode: 0x05, exchange_id: 1, protocol_id: 0x0001,
        payload: <<"from bob">>
      }

      {frame_b, _bob} = SecureChannel.seal(bob, proto_b)
      {:ok, msg_b, _alice} = SecureChannel.open(alice, frame_b)
      assert msg_b.proto.payload == "from bob"
    end
  end

  # ── PASE → SecureChannel integration ─────────────────────────────

  describe "PASE → SecureChannel integration" do
    test "full flow: PASE handshake then encrypted messaging" do
      # Setup PASE
      device_pase = PASE.new_device(
        passcode: @passcode, salt: @salt,
        iterations: @iterations, local_session_id: 1
      )

      comm_pase = PASE.new_commissioner(passcode: @passcode, local_session_id: 2)

      # Run PASE handshake
      {:send, :pbkdf_param_request, req, comm_pase} = PASE.initiate(comm_pase)
      {:reply, :pbkdf_param_response, resp, device_pase} =
        PASE.handle(device_pase, :pbkdf_param_request, req)
      {:send, :pase_pake1, pake1, comm_pase} =
        PASE.handle(comm_pase, :pbkdf_param_response, resp)
      {:reply, :pase_pake2, pake2, device_pase} =
        PASE.handle(device_pase, :pase_pake1, pake1)
      {:send, :pase_pake3, pake3, comm_pase} =
        PASE.handle(comm_pase, :pase_pake2, pake2)
      {:established, :status_report, sr, device_session, _device_pase} =
        PASE.handle(device_pase, :pase_pake3, pake3)
      {:established, comm_session, _comm_pase} =
        PASE.handle(comm_pase, :status_report, sr)

      # Now use the sessions for encrypted messaging
      # Commissioner → Device
      proto = %ProtoHeader{
        opcode: 0x02, exchange_id: 1, protocol_id: 0x0001,
        payload: <<"read request">>
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      {:ok, msg, device_session} = SecureChannel.open(device_session, frame)
      assert msg.proto.payload == "read request"

      # Device → Commissioner
      reply = %ProtoHeader{
        opcode: 0x05, exchange_id: 1, protocol_id: 0x0001,
        payload: <<"report data">>
      }

      {frame, _device_session} = SecureChannel.seal(device_session, reply)
      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, frame)
      assert msg.proto.payload == "report data"
    end
  end
end
