defmodule Matterlix.MessageHandlerTest do
  use ExUnit.Case

  alias Matterlix.MessageHandler
  alias Matterlix.{PASE, SecureChannel}
  alias Matterlix.IM
  alias Matterlix.Protocol.{MessageCodec, ProtocolID}
  alias Matterlix.Protocol.MessageCodec.{Header, ProtoHeader}

  @passcode 20202021
  @salt :crypto.strong_rand_bytes(32)
  @iterations 1000

  # Test device for IM routing
  defmodule TestLight do
    use Matterlix.Device,
      vendor_name: "TestCo",
      product_name: "TestLight",
      vendor_id: 0xFFF1,
      product_id: 0x8001

    endpoint 1, device_type: 0x0100 do
      cluster Matterlix.Cluster.OnOff
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp new_handler(opts \\ []) do
    device = Keyword.get(opts, :device)

    MessageHandler.new(
      device: device,
      passcode: @passcode,
      salt: @salt,
      iterations: @iterations,
      local_session_id: 1
    )
  end

  defp new_commissioner do
    PASE.new_commissioner(passcode: @passcode, local_session_id: 2)
  end

  # Build a plaintext frame for PASE message
  defp build_pase_frame(opcode_name, payload, exchange_id, opts \\ []) do
    counter = Keyword.get(opts, :counter, 0)

    header = %Header{
      session_id: 0,
      message_counter: counter,
      privacy: false,
      session_type: :unicast
    }

    opcode_num = ProtocolID.opcode(:secure_channel, opcode_name)

    proto = %ProtoHeader{
      initiator: true,
      opcode: opcode_num,
      exchange_id: exchange_id,
      protocol_id: 0x0000,
      payload: payload
    }

    IO.iodata_to_binary(MessageCodec.encode(header, proto))
  end

  # Run the full PASE handshake, returning {comm_session, handler}
  defp run_pase_handshake(handler) do
    comm = new_commissioner()
    exchange_id = 1

    # Step 1: Commissioner sends PBKDFParamRequest
    {:send, :pbkdf_param_request, req_payload, comm} = PASE.initiate(comm)
    frame = build_pase_frame(:pbkdf_param_request, req_payload, exchange_id, counter: 0)
    {actions, handler} = MessageHandler.handle_frame(handler, frame)
    [{:send, resp_frame}] = actions

    # Step 2: Commissioner processes PBKDFParamResponse
    {:ok, resp_msg} = MessageCodec.decode(resp_frame)
    {:send, :pase_pake1, pake1_payload, comm} =
      PASE.handle(comm, :pbkdf_param_response, resp_msg.proto.payload)

    # Step 3: Pake1
    frame = build_pase_frame(:pase_pake1, pake1_payload, exchange_id, counter: 1)
    {actions, handler} = MessageHandler.handle_frame(handler, frame)
    [{:send, pake2_frame}] = actions

    # Step 4: Commissioner processes Pake2
    {:ok, pake2_msg} = MessageCodec.decode(pake2_frame)
    {:send, :pase_pake3, pake3_payload, comm} =
      PASE.handle(comm, :pase_pake2, pake2_msg.proto.payload)

    # Step 5: Pake3
    frame = build_pase_frame(:pase_pake3, pake3_payload, exchange_id, counter: 2)
    {actions, handler} = MessageHandler.handle_frame(handler, frame)

    [{:send, sr_frame}, {:session_established, session_id}] = actions
    assert session_id == 1

    # Step 6: Commissioner processes StatusReport
    {:ok, sr_msg} = MessageCodec.decode(sr_frame)
    {:established, comm_session, _comm} =
      PASE.handle(comm, :status_report, sr_msg.proto.payload)

    {comm_session, handler}
  end

  # ── PASE via MessageHandler ─────────────────────────────────────

  describe "PASE via MessageHandler" do
    test "full PASE handshake produces session" do
      handler = new_handler()
      {comm_session, handler} = run_pase_handshake(handler)

      # Session is stored in handler
      assert Map.has_key?(handler.sessions, 1)

      # Commissioner has matching keys
      device_entry = handler.sessions[1]
      assert device_entry.session.encrypt_key == comm_session.decrypt_key
      assert device_entry.session.decrypt_key == comm_session.encrypt_key
    end

    test "PBKDFParamRequest returns PBKDFParamResponse frame" do
      handler = new_handler()
      comm = new_commissioner()

      {:send, :pbkdf_param_request, req_payload, _comm} = PASE.initiate(comm)
      frame = build_pase_frame(:pbkdf_param_request, req_payload, 1)

      {actions, handler} = MessageHandler.handle_frame(handler, frame)

      assert [{:send, resp_frame}] = actions
      {:ok, msg} = MessageCodec.decode(resp_frame)
      assert msg.header.session_id == 0
      assert msg.proto.opcode == ProtocolID.opcode(:secure_channel, :pbkdf_param_response)
      assert msg.proto.exchange_id == 1
      assert msg.proto.initiator == false

      # PASE state advanced
      assert handler.pase.state == :pbkdf_sent
    end

    test "wrong passcode causes error at Pake3" do
      handler = new_handler()

      # Commissioner with wrong passcode
      comm = PASE.new_commissioner(passcode: 12345678, local_session_id: 2)

      {:send, :pbkdf_param_request, req_payload, comm} = PASE.initiate(comm)
      frame = build_pase_frame(:pbkdf_param_request, req_payload, 1, counter: 0)
      {[{:send, resp_frame}], handler} = MessageHandler.handle_frame(handler, frame)

      {:ok, resp_msg} = MessageCodec.decode(resp_frame)
      {:send, :pase_pake1, pake1_payload, comm} =
        PASE.handle(comm, :pbkdf_param_response, resp_msg.proto.payload)

      frame = build_pase_frame(:pase_pake1, pake1_payload, 1, counter: 1)
      {[{:send, pake2_frame}], handler} = MessageHandler.handle_frame(handler, frame)

      {:ok, pake2_msg} = MessageCodec.decode(pake2_frame)

      # Commissioner fails at Pake2 verification (wrong passcode)
      assert {:error, :confirmation_failed} =
        PASE.handle(comm, :pase_pake2, pake2_msg.proto.payload)

      # No session established
      assert handler.sessions == %{}
    end
  end

  # ── Encrypted IM after PASE ─────────────────────────────────────

  describe "encrypted IM after PASE" do
    setup do
      start_supervised!(TestLight)

      handler = new_handler(device: TestLight)
      {comm_session, handler} = run_pase_handshake(handler)
      %{handler: handler, comm_session: comm_session}
    end

    test "ReadRequest → encrypted ReportData", %{handler: handler, comm_session: comm_session} do
      # Commissioner builds encrypted ReadRequest
      read_req = IM.encode(%IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        fabric_filtered: true
      })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :read_request),
        exchange_id: 1,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: read_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)

      # Handler processes encrypted frame
      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      # Should get send + schedule_mrp actions
      send_actions = Enum.filter(actions, &match?({:send, _}, &1))
      assert length(send_actions) == 1

      [{:send, resp_frame}] = send_actions

      # Commissioner decrypts response
      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, resp_frame)
      assert msg.proto.opcode == ProtocolID.opcode(:interaction_model, :report_data)

      {:ok, report} = IM.decode(:report_data, msg.proto.payload)
      assert %IM.ReportData{} = report
      assert length(report.attribute_reports) == 1
    end

    test "InvokeRequest → InvokeResponse", %{handler: handler, comm_session: comm_session} do
      invoke_req = IM.encode(%IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: 1, cluster: 6, command: 1}, fields: nil}
        ]
      })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :invoke_request),
        exchange_id: 2,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: invoke_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      [{:send, resp_frame} | _rest] = actions
      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, resp_frame)
      assert msg.proto.opcode == ProtocolID.opcode(:interaction_model, :invoke_response)
    end

    test "multiple IM round trips", %{handler: handler, comm_session: comm_session} do
      # Send 3 sequential ReadRequests
      {comm_session, handler} =
        Enum.reduce(1..3, {comm_session, handler}, fn i, {cs, h} ->
          read_req = IM.encode(%IM.ReadRequest{
            attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}]
          })

          proto = %ProtoHeader{
            initiator: true,
            needs_ack: true,
            opcode: ProtocolID.opcode(:interaction_model, :read_request),
            exchange_id: i,
            protocol_id: ProtocolID.protocol_id(:interaction_model),
            payload: read_req
          }

          {frame, cs} = SecureChannel.seal(cs, proto)
          {actions, h} = MessageHandler.handle_frame(h, frame)

          [{:send, resp_frame} | _] = actions
          {:ok, _msg, cs} = SecureChannel.open(cs, resp_frame)
          {cs, h}
        end)

      # All worked — no crash, sessions intact
      assert Map.has_key?(handler.sessions, 1)
      assert comm_session.counter != nil
    end
  end

  # ── Session management ──────────────────────────────────────────

  describe "session management" do
    test "unknown session_id returns error" do
      handler = new_handler()

      # Build a fake encrypted frame with session_id=99
      header = %Header{
        session_id: 99,
        message_counter: 0,
        privacy: true,
        session_type: :unicast
      }

      # Just the header bytes — will fail at session lookup before decrypt
      frame = IO.iodata_to_binary(Header.encode(header)) <> <<0::128>>

      {actions, _handler} = MessageHandler.handle_frame(handler, frame)
      assert [{:error, :unknown_session}] = actions
    end

    test "session stored after PASE has correct IDs" do
      handler = new_handler()
      {_comm_session, handler} = run_pase_handshake(handler)

      entry = handler.sessions[1]
      assert entry.session.local_session_id == 1
      assert entry.session.peer_session_id == 2
    end
  end

  # ── MRP timer handling ─────────────────────────────────────────

  describe "MRP timer handling" do
    setup do
      start_supervised!(TestLight)

      handler = new_handler(device: TestLight)
      {comm_session, handler} = run_pase_handshake(handler)
      %{handler: handler, comm_session: comm_session}
    end

    test "schedule_mrp action returned for IM response", %{handler: handler, comm_session: comm_session} do
      read_req = IM.encode(%IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}]
      })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :read_request),
        exchange_id: 1,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: read_req
      }

      {frame, _comm_session} = SecureChannel.seal(comm_session, proto)
      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      mrp_actions = Enum.filter(actions, &match?({:schedule_mrp, _, _, _, _}, &1))
      assert [{:schedule_mrp, 1, 1, 0, timeout}] = mrp_actions
      assert timeout > 0
    end

    test "handle_mrp_timeout for unknown session returns nil", %{handler: handler} do
      {action, _handler} = MessageHandler.handle_mrp_timeout(handler, 999, 1, 0)
      assert action == nil
    end
  end

  # ── Full end-to-end ─────────────────────────────────────────────

  describe "full end-to-end" do
    setup do
      start_supervised!(TestLight)
      :ok
    end

    test "PASE handshake → read attribute → verify value" do
      handler = new_handler(device: TestLight)
      {comm_session, handler} = run_pase_handshake(handler)

      # Read on_off attribute (should be false by default)
      read_req = IM.encode(%IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        fabric_filtered: true
      })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :read_request),
        exchange_id: 1,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: read_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      {actions, handler} = MessageHandler.handle_frame(handler, frame)
      [{:send, resp_frame} | _] = actions

      {:ok, msg, comm_session} = SecureChannel.open(comm_session, resp_frame)
      {:ok, report} = IM.decode(:report_data, msg.proto.payload)

      [{:data, data}] = report.attribute_reports
      assert data.value == false  # default on_off value

      # Invoke "on" command
      invoke_req = IM.encode(%IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: 1, cluster: 6, command: 1}, fields: nil}
        ]
      })

      proto2 = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :invoke_request),
        exchange_id: 2,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: invoke_req
      }

      {frame2, comm_session} = SecureChannel.seal(comm_session, proto2)
      {actions2, handler} = MessageHandler.handle_frame(handler, frame2)
      [{:send, _invoke_resp} | _] = actions2

      # Read again — should now be true
      read_req2 = IM.encode(%IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        fabric_filtered: true
      })

      proto3 = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :read_request),
        exchange_id: 3,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: read_req2
      }

      {frame3, comm_session} = SecureChannel.seal(comm_session, proto3)
      {actions3, _handler} = MessageHandler.handle_frame(handler, frame3)
      [{:send, resp_frame3} | _] = actions3

      {:ok, msg3, _comm_session} = SecureChannel.open(comm_session, resp_frame3)
      {:ok, report3} = IM.decode(:report_data, msg3.proto.payload)

      [{:data, data3}] = report3.attribute_reports
      assert data3.value == true  # on_off is now true!
    end
  end
end
