defmodule MatterEx.PASETest do
  use ExUnit.Case, async: true

  alias MatterEx.PASE
  alias MatterEx.PASE.Messages
  alias MatterEx.Protocol.StatusReport
  alias MatterEx.Session

  @passcode 20202021
  @salt :crypto.strong_rand_bytes(32)
  @iterations 1000

  # ── StatusReport codec ─────────────────────────────────────────────

  describe "StatusReport" do
    test "encode/decode roundtrip" do
      sr = %StatusReport{general_code: 0, protocol_id: 0, protocol_code: 0}
      encoded = StatusReport.encode(sr)
      assert {:ok, decoded} = StatusReport.decode(encoded)
      assert decoded.general_code == 0
      assert decoded.protocol_id == 0
      assert decoded.protocol_code == 0
    end

    test "encode/decode failure status" do
      sr = %StatusReport{general_code: 1, protocol_id: 0, protocol_code: 2}
      encoded = StatusReport.encode(sr)
      assert {:ok, decoded} = StatusReport.decode(encoded)
      assert decoded.general_code == 1
      assert decoded.protocol_code == 2
    end

    test "decode invalid binary" do
      assert {:error, :invalid_status_report} = StatusReport.decode(<<1, 2>>)
    end

    test "encode produces 8 bytes" do
      sr = %StatusReport{general_code: 0, protocol_id: 0, protocol_code: 0}
      assert byte_size(StatusReport.encode(sr)) == 8
    end
  end

  # ── Session struct ──────────────────────────────────────────────────

  describe "Session" do
    test "new creates session with counter" do
      session = Session.new(
        local_session_id: 1,
        peer_session_id: 2,
        encryption_key: :crypto.strong_rand_bytes(16)
      )

      assert session.local_session_id == 1
      assert session.peer_session_id == 2
      assert session.counter != nil
    end

    test "derives directional keys from Ke" do
      ke = :crypto.strong_rand_bytes(16)
      session = Session.new(
        local_session_id: 100,
        peer_session_id: 200,
        encryption_key: ke
      )

      assert byte_size(session.encrypt_key) == 16
      assert byte_size(session.decrypt_key) == 16
      assert byte_size(session.attestation_challenge) == 16
      assert session.encrypt_key != session.decrypt_key
    end
  end

  # ── PASE Messages codec ────────────────────────────────────────────

  describe "PASE Messages" do
    test "PBKDFParamRequest roundtrip" do
      random = :crypto.strong_rand_bytes(32)
      encoded = Messages.encode_pbkdf_param_request(random, 42)
      assert {:ok, decoded} = Messages.decode_pbkdf_param_request(encoded)
      assert decoded.initiator_random == random
      assert decoded.initiator_session_id == 42
      assert decoded.passcode_id == 0
      assert decoded.has_pbkdf_params == false
    end

    test "PBKDFParamRequest with options" do
      random = :crypto.strong_rand_bytes(32)
      encoded = Messages.encode_pbkdf_param_request(random, 10, passcode_id: 1, has_pbkdf_params: true)
      assert {:ok, decoded} = Messages.decode_pbkdf_param_request(encoded)
      assert decoded.passcode_id == 1
      assert decoded.has_pbkdf_params == true
    end

    test "PBKDFParamResponse roundtrip" do
      init_random = :crypto.strong_rand_bytes(32)
      resp_random = :crypto.strong_rand_bytes(32)
      salt = :crypto.strong_rand_bytes(32)

      encoded = Messages.encode_pbkdf_param_response(init_random, resp_random, 99, 1000, salt)
      assert {:ok, decoded} = Messages.decode_pbkdf_param_response(encoded)
      assert decoded.initiator_random == init_random
      assert decoded.responder_random == resp_random
      assert decoded.responder_session_id == 99
      assert decoded.pbkdf_parameters.iterations == 1000
      assert decoded.pbkdf_parameters.salt == salt
    end

    test "Pake1 roundtrip" do
      pa = :crypto.strong_rand_bytes(65)
      encoded = Messages.encode_pake1(pa)
      assert {:ok, decoded} = Messages.decode_pake1(encoded)
      assert decoded.pa == pa
    end

    test "Pake2 roundtrip" do
      pb = :crypto.strong_rand_bytes(65)
      cb = :crypto.strong_rand_bytes(32)
      encoded = Messages.encode_pake2(pb, cb)
      assert {:ok, decoded} = Messages.decode_pake2(encoded)
      assert decoded.pb == pb
      assert decoded.cb == cb
    end

    test "Pake3 roundtrip" do
      ca = :crypto.strong_rand_bytes(32)
      encoded = Messages.encode_pake3(ca)
      assert {:ok, decoded} = Messages.decode_pake3(encoded)
      assert decoded.ca == ca
    end

    test "decode invalid data returns error" do
      assert {:error, :invalid_message} = Messages.decode_pake1(<<>>)
      assert {:error, :invalid_message} = Messages.decode_pake2(<<>>)
      assert {:error, :invalid_message} = Messages.decode_pake3(<<>>)
    end
  end

  # ── PASE device flow ───────────────────────────────────────────────

  describe "PASE device flow" do
    test "handle PBKDFParamRequest → sends PBKDFParamResponse" do
      device = PASE.new_device(
        passcode: @passcode, salt: @salt,
        iterations: @iterations, local_session_id: 1
      )

      random = :crypto.strong_rand_bytes(32)
      req_payload = Messages.encode_pbkdf_param_request(random, 42)

      assert {:reply, :pbkdf_param_response, resp_payload, device} =
        PASE.handle(device, :pbkdf_param_request, req_payload)

      assert {:ok, resp} = Messages.decode_pbkdf_param_response(resp_payload)
      assert resp.initiator_random == random
      assert resp.responder_session_id == 1
      assert resp.pbkdf_parameters.iterations == @iterations
      assert resp.pbkdf_parameters.salt == @salt
      assert device.state == :pbkdf_sent
      assert device.peer_session_id == 42
    end
  end

  # ── PASE commissioner flow ─────────────────────────────────────────

  describe "PASE commissioner flow" do
    test "initiate sends PBKDFParamRequest" do
      comm = PASE.new_commissioner(passcode: @passcode, local_session_id: 2)
      assert {:send, :pbkdf_param_request, payload, comm} = PASE.initiate(comm)

      assert {:ok, msg} = Messages.decode_pbkdf_param_request(payload)
      assert byte_size(msg.initiator_random) == 32
      assert msg.initiator_session_id == 2
      assert comm.state == :pbkdf_sent
    end
  end

  # ── Full end-to-end ─────────────────────────────────────────────────

  describe "full PASE end-to-end" do
    test "commissioner ↔ device complete handshake" do
      # Setup
      device = PASE.new_device(
        passcode: @passcode, salt: @salt,
        iterations: @iterations, local_session_id: 1
      )

      comm = PASE.new_commissioner(passcode: @passcode, local_session_id: 2)

      # Step 1: Commissioner sends PBKDFParamRequest
      {:send, :pbkdf_param_request, req_payload, comm} = PASE.initiate(comm)

      # Step 2: Device receives PBKDFParamRequest → sends PBKDFParamResponse
      {:reply, :pbkdf_param_response, resp_payload, device} =
        PASE.handle(device, :pbkdf_param_request, req_payload)

      # Step 3: Commissioner receives PBKDFParamResponse → sends Pake1
      {:send, :pase_pake1, pake1_payload, comm} =
        PASE.handle(comm, :pbkdf_param_response, resp_payload)

      # Step 4: Device receives Pake1 → sends Pake2
      {:reply, :pase_pake2, pake2_payload, device} =
        PASE.handle(device, :pase_pake1, pake1_payload)

      # Step 5: Commissioner receives Pake2 → sends Pake3
      {:send, :pase_pake3, pake3_payload, comm} =
        PASE.handle(comm, :pase_pake2, pake2_payload)

      # Step 6: Device receives Pake3 → sends StatusReport, established
      {:established, :status_report, sr_payload, device_session, _device} =
        PASE.handle(device, :pase_pake3, pake3_payload)

      # Step 7: Commissioner receives StatusReport → established
      {:established, comm_session, _comm} =
        PASE.handle(comm, :status_report, sr_payload)

      # Device encrypt_key == Commissioner decrypt_key (and vice versa)
      assert device_session.encrypt_key == comm_session.decrypt_key
      assert device_session.decrypt_key == comm_session.encrypt_key
      assert byte_size(device_session.encrypt_key) == 16

      # Session IDs are crossed
      assert device_session.local_session_id == 1
      assert device_session.peer_session_id == 2
      assert comm_session.local_session_id == 2
      assert comm_session.peer_session_id == 1
    end

    test "different passcodes cause confirmation failure" do
      device = PASE.new_device(
        passcode: @passcode, salt: @salt,
        iterations: @iterations, local_session_id: 1
      )

      comm = PASE.new_commissioner(passcode: 12345678, local_session_id: 2)

      {:send, :pbkdf_param_request, req_payload, comm} = PASE.initiate(comm)

      {:reply, :pbkdf_param_response, resp_payload, device} =
        PASE.handle(device, :pbkdf_param_request, req_payload)

      {:send, :pase_pake1, pake1_payload, comm} =
        PASE.handle(comm, :pbkdf_param_response, resp_payload)

      {:reply, :pase_pake2, pake2_payload, _device} =
        PASE.handle(device, :pase_pake1, pake1_payload)

      # Commissioner should fail to verify cB since keys don't match
      assert {:error, :confirmation_failed} =
        PASE.handle(comm, :pase_pake2, pake2_payload)
    end

    test "multiple handshakes produce different keys" do
      device1 = PASE.new_device(
        passcode: @passcode, salt: @salt,
        iterations: @iterations, local_session_id: 1
      )

      device2 = PASE.new_device(
        passcode: @passcode, salt: @salt,
        iterations: @iterations, local_session_id: 3
      )

      comm1 = PASE.new_commissioner(passcode: @passcode, local_session_id: 2)
      comm2 = PASE.new_commissioner(passcode: @passcode, local_session_id: 4)

      # Run two full handshakes
      session1 = run_full_handshake(comm1, device1)
      session2 = run_full_handshake(comm2, device2)

      # Different random values mean different keys
      assert session1.encrypt_key != session2.encrypt_key
    end
  end

  # ── Error cases ─────────────────────────────────────────────────────

  describe "error cases" do
    test "message in wrong state" do
      device = PASE.new_device(
        passcode: @passcode, salt: @salt,
        iterations: @iterations, local_session_id: 1
      )

      # Device is in :idle, should not accept Pake1
      assert {:error, :unexpected_message} =
        PASE.handle(device, :pase_pake1, <<>>)
    end

    test "commissioner message in wrong state" do
      comm = PASE.new_commissioner(passcode: @passcode, local_session_id: 2)

      # Commissioner is in :idle, should not accept PBKDFParamResponse
      assert {:error, :unexpected_message} =
        PASE.handle(comm, :pbkdf_param_response, <<>>)
    end

    test "malformed PBKDFParamRequest" do
      device = PASE.new_device(
        passcode: @passcode, salt: @salt,
        iterations: @iterations, local_session_id: 1
      )

      assert {:error, _reason} = PASE.handle(device, :pbkdf_param_request, <<0>>)
    end

    test "device rejects bad cA in Pake3" do
      device = PASE.new_device(
        passcode: @passcode, salt: @salt,
        iterations: @iterations, local_session_id: 1
      )

      comm = PASE.new_commissioner(passcode: @passcode, local_session_id: 2)

      {:send, :pbkdf_param_request, req_payload, comm} = PASE.initiate(comm)
      {:reply, :pbkdf_param_response, resp_payload, device} =
        PASE.handle(device, :pbkdf_param_request, req_payload)
      {:send, :pase_pake1, pake1_payload, _comm} =
        PASE.handle(comm, :pbkdf_param_response, resp_payload)
      {:reply, :pase_pake2, _pake2_payload, device} =
        PASE.handle(device, :pase_pake1, pake1_payload)

      # Send a fake cA
      fake_pake3 = Messages.encode_pake3(:crypto.strong_rand_bytes(32))

      assert {:error, :confirmation_failed} =
        PASE.handle(device, :pase_pake3, fake_pake3)
    end

    test "commissioner rejects failed StatusReport" do
      device = PASE.new_device(
        passcode: @passcode, salt: @salt,
        iterations: @iterations, local_session_id: 1
      )

      comm = PASE.new_commissioner(passcode: @passcode, local_session_id: 2)

      # Run through to pake3_sent state
      {:send, :pbkdf_param_request, req_payload, comm} = PASE.initiate(comm)
      {:reply, :pbkdf_param_response, resp_payload, device} =
        PASE.handle(device, :pbkdf_param_request, req_payload)
      {:send, :pase_pake1, pake1_payload, comm} =
        PASE.handle(comm, :pbkdf_param_response, resp_payload)
      {:reply, :pase_pake2, pake2_payload, _device} =
        PASE.handle(device, :pase_pake1, pake1_payload)
      {:send, :pase_pake3, _pake3_payload, comm} =
        PASE.handle(comm, :pase_pake2, pake2_payload)

      # Send a failure StatusReport instead of success
      failure_sr = StatusReport.encode(%StatusReport{
        general_code: 1, protocol_id: 0, protocol_code: 2
      })

      assert {:error, :session_establishment_failed} =
        PASE.handle(comm, :status_report, failure_sr)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp run_full_handshake(comm, device) do
    {:send, :pbkdf_param_request, req, comm} = PASE.initiate(comm)
    {:reply, :pbkdf_param_response, resp, device} = PASE.handle(device, :pbkdf_param_request, req)
    {:send, :pase_pake1, pake1, comm} = PASE.handle(comm, :pbkdf_param_response, resp)
    {:reply, :pase_pake2, pake2, device} = PASE.handle(device, :pase_pake1, pake1)
    {:send, :pase_pake3, pake3, comm} = PASE.handle(comm, :pase_pake2, pake2)
    {:established, :status_report, sr, _session, _device} = PASE.handle(device, :pase_pake3, pake3)
    {:established, session, _comm} = PASE.handle(comm, :status_report, sr)
    session
  end
end
