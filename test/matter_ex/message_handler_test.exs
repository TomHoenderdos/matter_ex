defmodule MatterEx.MessageHandlerTest do
  use ExUnit.Case

  alias MatterEx.MessageHandler
  alias MatterEx.{PASE, SecureChannel}
  alias MatterEx.IM
  alias MatterEx.Protocol.{MessageCodec, ProtocolID}
  alias MatterEx.Protocol.MessageCodec.{Header, ProtoHeader}

  @passcode 20202021
  @salt :crypto.strong_rand_bytes(32)
  @iterations 1000

  # Test device for IM routing
  defmodule TestLight do
    use MatterEx.Device,
      vendor_name: "TestCo",
      product_name: "TestLight",
      vendor_id: 0xFFF1,
      product_id: 0x8001

    endpoint 1, device_type: 0x0100 do
      cluster MatterEx.Cluster.OnOff
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp seed_acl(device, subject, privilege \\ 5) do
    acl_name = device.__process_name__(0, :access_control)

    entry = %{
      privilege: privilege,
      auth_mode: 2,
      subjects: [subject],
      targets: nil,
      fabric_index: 1
    }

    GenServer.call(acl_name, {:write_attribute, :acl, [entry]})
  end

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

  # Helper: complete the subscribe two-phase flow by sending StatusResponse
  # and receiving the SubscribeResponse. `priming_msg` is the decrypted priming
  # ReportData message from the first phase.
  defp complete_subscribe(comm_session, handler, priming_msg, exchange_id) do
    status_resp = IM.encode(%IM.StatusResponse{status: 0})
    status_proto = %ProtoHeader{
      initiator: true,
      needs_ack: true,
      ack_counter: priming_msg.header.message_counter,
      opcode: ProtocolID.opcode(:interaction_model, :status_response),
      exchange_id: exchange_id,
      protocol_id: ProtocolID.protocol_id(:interaction_model),
      payload: status_resp
    }

    {status_frame, comm_session} = SecureChannel.seal(comm_session, status_proto)
    {actions, handler} = MessageHandler.handle_frame(handler, status_frame)
    [{:send, sub_resp_frame} | _] = actions
    {:ok, _sub_msg, comm_session} = SecureChannel.open(comm_session, sub_resp_frame)
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

    test "standalone ACK sent for message with no response", %{handler: handler, comm_session: comm_session} do
      # Send a ReportData (opcode 0x05) — a response-type message with no reply expected
      # This triggers the :no_response path which produces a standalone ACK
      report = IM.encode(%IM.ReportData{attribute_reports: []})

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :report_data),
        exchange_id: 99,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: report
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      # Should get a standalone ACK frame (no content reply)
      send_actions = Enum.filter(actions, &match?({:send, _}, &1))
      assert length(send_actions) == 1

      [{:send, ack_frame}] = send_actions
      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, ack_frame)

      # Verify it's a standalone ACK
      assert msg.proto.opcode == ProtocolID.opcode(:secure_channel, :standalone_ack)
      assert msg.proto.protocol_id == ProtocolID.protocol_id(:secure_channel)
      assert msg.proto.exchange_id == 99
      assert msg.proto.initiator == false
      assert msg.proto.needs_ack == false
      assert msg.proto.payload == <<>>
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

  # ── Subscribe via MessageHandler ───────────────────────────────

  describe "subscribe via MessageHandler" do
    setup do
      start_supervised!(TestLight)

      handler = new_handler(device: TestLight)
      {comm_session, handler} = run_pase_handshake(handler)
      %{handler: handler, comm_session: comm_session}
    end

    test "SubscribeRequest → priming ReportData → StatusResponse → SubscribeResponse",
         %{handler: handler, comm_session: comm_session} do
      sub_req = IM.encode(%IM.SubscribeRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        min_interval: 0,
        max_interval: 60
      })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :subscribe_request),
        exchange_id: 1,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: sub_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      {actions, handler} = MessageHandler.handle_frame(handler, frame)

      # Phase 1: priming ReportData
      send_actions = Enum.filter(actions, &match?({:send, _}, &1))
      assert length(send_actions) == 1

      [{:send, resp_frame}] = send_actions
      {:ok, msg, comm_session} = SecureChannel.open(comm_session, resp_frame)
      assert msg.proto.opcode == ProtocolID.opcode(:interaction_model, :report_data)

      {:ok, report} = IM.decode(:report_data, msg.proto.payload)
      assert report.subscription_id == 1

      # Phase 2: send StatusResponse to ACK the priming report
      status_resp = IM.encode(%IM.StatusResponse{status: 0})
      status_proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        ack_counter: msg.header.message_counter,
        opcode: ProtocolID.opcode(:interaction_model, :status_response),
        exchange_id: 1,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: status_resp
      }

      {status_frame, comm_session} = SecureChannel.seal(comm_session, status_proto)
      {actions2, handler} = MessageHandler.handle_frame(handler, status_frame)

      # Phase 3: SubscribeResponse
      send_actions2 = Enum.filter(actions2, &match?({:send, _}, &1))
      assert length(send_actions2) == 1

      [{:send, sub_resp_frame}] = send_actions2
      {:ok, sub_msg, _comm_session} = SecureChannel.open(comm_session, sub_resp_frame)
      assert sub_msg.proto.opcode == ProtocolID.opcode(:interaction_model, :subscribe_response)

      {:ok, sub_resp} = IM.decode(:subscribe_response, sub_msg.proto.payload)
      assert sub_resp.subscription_id == 1
      assert sub_resp.max_interval == 60

      # Subscription is stored in session entry
      entry = handler.sessions[1]
      assert MatterEx.IM.SubscriptionManager.active?(entry.subscription_mgr)
    end

    test "multiple subscriptions get incrementing IDs",
         %{handler: handler, comm_session: comm_session} do
      # First subscription — phase 1: priming ReportData
      sub_req1 = IM.encode(%IM.SubscribeRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        min_interval: 0,
        max_interval: 30
      })

      proto1 = %ProtoHeader{
        initiator: true, needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :subscribe_request),
        exchange_id: 1, protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: sub_req1
      }

      {frame1, comm_session} = SecureChannel.seal(comm_session, proto1)
      {actions1, handler} = MessageHandler.handle_frame(handler, frame1)
      [{:send, resp1} | _] = actions1
      {:ok, msg1, comm_session} = SecureChannel.open(comm_session, resp1)
      {:ok, report1} = IM.decode(:report_data, msg1.proto.payload)
      assert report1.subscription_id == 1

      # First subscription — phase 2: StatusResponse → SubscribeResponse
      {comm_session, handler} = complete_subscribe(comm_session, handler, msg1, 1)

      # Second subscription — phase 1: priming ReportData
      sub_req2 = IM.encode(%IM.SubscribeRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        min_interval: 5,
        max_interval: 120
      })

      proto2 = %ProtoHeader{
        initiator: true, needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :subscribe_request),
        exchange_id: 2, protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: sub_req2
      }

      {frame2, comm_session} = SecureChannel.seal(comm_session, proto2)
      {actions2, handler} = MessageHandler.handle_frame(handler, frame2)
      [{:send, resp2} | _] = actions2
      {:ok, msg2, comm_session} = SecureChannel.open(comm_session, resp2)
      {:ok, report2} = IM.decode(:report_data, msg2.proto.payload)
      assert report2.subscription_id == 2

      # Second subscription — phase 2: StatusResponse → SubscribeResponse
      {_comm_session, handler} = complete_subscribe(comm_session, handler, msg2, 2)

      # Both subscriptions stored
      entry = handler.sessions[1]
      subs = MatterEx.IM.SubscriptionManager.subscriptions(entry.subscription_mgr)
      assert length(subs) == 2
    end

    test "check_subscriptions sends report when values change",
         %{handler: handler, comm_session: comm_session} do
      # Subscribe
      sub_req = IM.encode(%IM.SubscribeRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        min_interval: 0,
        max_interval: 0  # immediately due
      })

      proto = %ProtoHeader{
        initiator: true, needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :subscribe_request),
        exchange_id: 1, protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: sub_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      {_actions, handler} = MessageHandler.handle_frame(handler, frame)

      # First check — initial values (false) differ from empty last_values
      {actions, handler} = MessageHandler.check_subscriptions(handler)
      send_actions = Enum.filter(actions, &match?({:send, _}, &1))
      assert length(send_actions) == 1

      [{:send, report_frame}] = send_actions
      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, report_frame)
      assert msg.proto.opcode == ProtocolID.opcode(:interaction_model, :report_data)

      {:ok, report} = IM.decode(:report_data, msg.proto.payload)
      assert report.subscription_id == 1
      assert length(report.attribute_reports) == 1

      # Second check — no change, so no report
      # Wait briefly so max_interval (0) is satisfied
      Process.sleep(1)
      {actions2, _handler} = MessageHandler.check_subscriptions(handler)
      send_actions2 = Enum.filter(actions2, &match?({:send, _}, &1))
      assert send_actions2 == []
    end
  end

  # ── suppress_response (Phase 26) ────────────────────────────────

  describe "suppress_response handling" do
    setup do
      start_supervised!(TestLight)

      handler = new_handler(device: TestLight)
      {comm_session, handler} = run_pase_handshake(handler)
      %{handler: handler, comm_session: comm_session}
    end

    test "WriteRequest with suppress_response skips WriteResponse, sends ACK",
         %{handler: handler, comm_session: comm_session} do
      write_req = IM.encode(%IM.WriteRequest{
        suppress_response: true,
        write_requests: [
          %{path: %{endpoint: 1, cluster: 6, attribute: 0}, value: {:bool, true}, version: 0}
        ]
      })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :write_request),
        exchange_id: 1,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: write_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      # Should get a standalone ACK, not a WriteResponse
      send_actions = Enum.filter(actions, &match?({:send, _}, &1))
      assert length(send_actions) == 1

      [{:send, ack_frame}] = send_actions
      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, ack_frame)

      # Verify it's a standalone ACK (secure_channel protocol), not a WriteResponse
      assert msg.proto.opcode == ProtocolID.opcode(:secure_channel, :standalone_ack)
      assert msg.proto.protocol_id == ProtocolID.protocol_id(:secure_channel)
    end

    test "InvokeRequest with suppress_response skips InvokeResponse, sends ACK",
         %{handler: handler, comm_session: comm_session} do
      invoke_req = IM.encode(%IM.InvokeRequest{
        suppress_response: true,
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

      send_actions = Enum.filter(actions, &match?({:send, _}, &1))
      assert length(send_actions) == 1

      [{:send, ack_frame}] = send_actions
      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, ack_frame)

      assert msg.proto.opcode == ProtocolID.opcode(:secure_channel, :standalone_ack)
    end

    test "InvokeRequest with suppress_response still executes the command",
         %{handler: handler, comm_session: comm_session} do
      # Invoke "on" command with suppress_response
      invoke_req = IM.encode(%IM.InvokeRequest{
        suppress_response: true,
        invoke_requests: [
          %{path: %{endpoint: 1, cluster: 6, command: 1}, fields: nil}
        ]
      })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :invoke_request),
        exchange_id: 1,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: invoke_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      {_actions, handler} = MessageHandler.handle_frame(handler, frame)

      # Read the attribute to verify the command was executed
      read_req = IM.encode(%IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}]
      })

      proto2 = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :read_request),
        exchange_id: 2,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: read_req
      }

      {frame2, comm_session} = SecureChannel.seal(comm_session, proto2)
      {actions, _handler} = MessageHandler.handle_frame(handler, frame2)

      [{:send, resp_frame} | _] = actions
      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, resp_frame)
      {:ok, report} = IM.decode(:report_data, msg.proto.payload)

      [{:data, data}] = report.attribute_reports
      assert data.value == true
    end

    test "WriteRequest without suppress_response still sends WriteResponse",
         %{handler: handler, comm_session: comm_session} do
      write_req = IM.encode(%IM.WriteRequest{
        suppress_response: false,
        write_requests: [
          %{path: %{endpoint: 1, cluster: 6, attribute: 0}, value: {:bool, true}, version: 0}
        ]
      })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :write_request),
        exchange_id: 1,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: write_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      send_actions = Enum.filter(actions, &match?({:send, _}, &1))
      assert length(send_actions) == 1

      [{:send, resp_frame}] = send_actions
      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, resp_frame)

      # Should be a WriteResponse, not a standalone ACK
      assert msg.proto.opcode == ProtocolID.opcode(:interaction_model, :write_response)
    end
  end

  # ── Subscription lifecycle (Phase 25) ───────────────────────────

  describe "subscription lifecycle" do
    setup do
      start_supervised!(TestLight)

      handler = new_handler(device: TestLight)
      {comm_session, handler} = run_pase_handshake(handler)
      %{handler: handler, comm_session: comm_session}
    end

    test "min_interval throttle suppresses early reports",
         %{handler: handler, comm_session: comm_session} do
      # Subscribe with min_interval=60 seconds, max_interval=0 (immediately due)
      sub_req = IM.encode(%IM.SubscribeRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        min_interval: 60,
        max_interval: 0
      })

      proto = %ProtoHeader{
        initiator: true, needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :subscribe_request),
        exchange_id: 1, protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: sub_req
      }

      {frame, _comm_session} = SecureChannel.seal(comm_session, proto)
      {_actions, handler} = MessageHandler.handle_frame(handler, frame)

      # First check — initial values differ from empty last_values, sends report
      {actions1, handler} = MessageHandler.check_subscriptions(handler)
      send_actions1 = Enum.filter(actions1, &match?({:send, _}, &1))
      assert length(send_actions1) == 1

      # Toggle the light so values change
      on_off_name = TestLight.__process_name__(1, :on_off)
      GenServer.call(on_off_name, {:write_attribute, :on_off, true})

      # Second check — values changed BUT min_interval (60s) not elapsed
      {actions2, _handler} = MessageHandler.check_subscriptions(handler)
      send_actions2 = Enum.filter(actions2, &match?({:send, _}, &1))
      assert send_actions2 == []
    end

    test "min_interval=0 allows immediate reports",
         %{handler: handler, comm_session: comm_session} do
      sub_req = IM.encode(%IM.SubscribeRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        min_interval: 0,
        max_interval: 0
      })

      proto = %ProtoHeader{
        initiator: true, needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :subscribe_request),
        exchange_id: 1, protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: sub_req
      }

      {frame, _comm_session} = SecureChannel.seal(comm_session, proto)
      {_actions, handler} = MessageHandler.handle_frame(handler, frame)

      # First report
      {actions1, handler} = MessageHandler.check_subscriptions(handler)
      assert length(Enum.filter(actions1, &match?({:send, _}, &1))) == 1

      # Toggle value
      on_off_name = TestLight.__process_name__(1, :on_off)
      GenServer.call(on_off_name, {:write_attribute, :on_off, true})

      # Second report — min_interval=0 means no throttle
      Process.sleep(1)
      {actions2, _handler} = MessageHandler.check_subscriptions(handler)
      assert length(Enum.filter(actions2, &match?({:send, _}, &1))) == 1
    end

    test "close_session removes session and subscriptions",
         %{handler: handler, comm_session: comm_session} do
      # Subscribe
      sub_req = IM.encode(%IM.SubscribeRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        min_interval: 0,
        max_interval: 60
      })

      proto = %ProtoHeader{
        initiator: true, needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :subscribe_request),
        exchange_id: 1, protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: sub_req
      }

      {frame, _comm_session} = SecureChannel.seal(comm_session, proto)
      {_actions, handler} = MessageHandler.handle_frame(handler, frame)

      # Verify session exists with active subscription
      assert Map.has_key?(handler.sessions, 1)
      assert MatterEx.IM.SubscriptionManager.active?(handler.sessions[1].subscription_mgr)

      # Close session
      {actions, handler} = MessageHandler.close_session(handler, 1)
      assert [{:session_closed, 1}] = actions
      refute Map.has_key?(handler.sessions, 1)

      # check_subscriptions produces nothing (no sessions)
      {actions, _handler} = MessageHandler.check_subscriptions(handler)
      assert actions == []
    end

    test "close_session for non-existent session is no-op", %{handler: handler} do
      {actions, _handler} = MessageHandler.close_session(handler, 999)
      assert actions == []
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

  # ── CASE via MessageHandler ────────────────────────────────────

  describe "CASE via MessageHandler" do
    setup do
      start_supervised!(TestLight)
      :ok
    end

    defp new_handler_with_case(opts) do
      device = Keyword.get(opts, :device)

      {pub, priv} = MatterEx.Crypto.Certificate.generate_keypair()
      noc = MatterEx.CASE.Messages.encode_noc(1, 1, pub)
      ipk = Keyword.get(opts, :ipk, :crypto.strong_rand_bytes(16))

      handler = MessageHandler.new(
        device: device,
        passcode: @passcode,
        salt: @salt,
        iterations: @iterations,
        local_session_id: 1,
        noc: noc,
        private_key: priv,
        ipk: ipk,
        node_id: 1,
        fabric_id: 1
      )

      {handler, ipk}
    end

    defp new_case_initiator(ipk) do
      {pub, priv} = MatterEx.Crypto.Certificate.generate_keypair()
      noc = MatterEx.CASE.Messages.encode_noc(2, 1, pub)

      MatterEx.CASE.new_initiator(
        noc: noc,
        private_key: priv,
        ipk: ipk,
        node_id: 2,
        fabric_id: 1,
        local_session_id: 100,
        peer_node_id: 1,
        peer_fabric_id: 1
      )
    end

    defp build_case_frame(opcode_name, payload, exchange_id, counter) do
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

    defp run_case_handshake(handler, ipk) do
      init = new_case_initiator(ipk)
      exchange_id = 10

      # Step 1: Initiator sends Sigma1
      {:send, :case_sigma1, sigma1_payload, init} = MatterEx.CASE.initiate(init)
      frame = build_case_frame(:case_sigma1, sigma1_payload, exchange_id, 0)
      {actions, handler} = MessageHandler.handle_frame(handler, frame)
      [{:send, sigma2_frame}] = actions

      # Step 2: Initiator processes Sigma2
      {:ok, sigma2_msg} = MessageCodec.decode(sigma2_frame)
      {:send, :case_sigma3, sigma3_payload, init} =
        MatterEx.CASE.handle(init, :case_sigma2, sigma2_msg.proto.payload)

      # Step 3: Initiator sends Sigma3
      frame = build_case_frame(:case_sigma3, sigma3_payload, exchange_id, 1)
      {actions, handler} = MessageHandler.handle_frame(handler, frame)

      [{:send, sr_frame}, {:session_established, session_id}] = actions
      assert session_id > 0

      # Step 4: Initiator processes StatusReport
      {:ok, sr_msg} = MessageCodec.decode(sr_frame)
      {:established, init_session, _init} =
        MatterEx.CASE.handle(init, :status_report, sr_msg.proto.payload)

      {init_session, handler, session_id}
    end

    test "Sigma1 → Sigma2 response via MessageHandler" do
      {handler, ipk} = new_handler_with_case(device: TestLight)
      init = new_case_initiator(ipk)

      {:send, :case_sigma1, sigma1_payload, _init} = MatterEx.CASE.initiate(init)
      frame = build_case_frame(:case_sigma1, sigma1_payload, 10, 0)

      {actions, handler} = MessageHandler.handle_frame(handler, frame)
      assert [{:send, sigma2_frame}] = actions

      {:ok, msg} = MessageCodec.decode(sigma2_frame)
      assert msg.proto.opcode == ProtocolID.opcode(:secure_channel, :case_sigma2)
      assert msg.proto.initiator == false

      # CASE state advanced (fabric_index 1)
      assert handler.case_states[1].state == :sigma2_sent
    end

    test "full CASE handshake through MessageHandler → session established" do
      {handler, ipk} = new_handler_with_case(device: TestLight)
      {_init_session, handler, session_id} = run_case_handshake(handler, ipk)

      assert Map.has_key?(handler.sessions, session_id)
      entry = handler.sessions[session_id]
      assert entry.session.local_session_id == session_id
    end

    test "encrypted IM after CASE session with ACL" do
      {handler, ipk} = new_handler_with_case(device: TestLight)
      {init_session, handler, _session_id} = run_case_handshake(handler, ipk)

      # Seed admin ACL entry for the CASE initiator (node_id=2, fabric=1)
      seed_acl(TestLight, 2)

      # Read on_off via CASE-established session
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

      {frame, init_session} = SecureChannel.seal(init_session, proto)
      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      send_actions = Enum.filter(actions, &match?({:send, _}, &1))
      assert length(send_actions) == 1

      [{:send, resp_frame}] = send_actions
      {:ok, msg, _init_session} = SecureChannel.open(init_session, resp_frame)
      assert msg.proto.opcode == ProtocolID.opcode(:interaction_model, :report_data)

      {:ok, report} = IM.decode(:report_data, msg.proto.payload)
      assert [{:data, _data}] = report.attribute_reports
    end

    test "PASE and CASE can coexist" do
      {handler, ipk} = new_handler_with_case(device: TestLight)

      # First: PASE handshake
      {_pase_session, handler} = run_pase_handshake(handler)
      assert Map.has_key?(handler.sessions, 1)

      # Then: CASE handshake
      {_init_session, handler, case_session_id} = run_case_handshake(handler, ipk)
      assert Map.has_key?(handler.sessions, case_session_id)

      # Both sessions exist
      assert map_size(handler.sessions) == 2
    end

    test "case_sigma2_resume routed to CASE handler, not PASE" do
      {handler, _ipk} = new_handler_with_case(device: TestLight)

      # Send a case_sigma2_resume opcode — should go to CASE handler (error),
      # not crash in PASE
      frame = build_case_frame(:case_sigma2_resume, <<>>, 99, 0)
      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      assert [{:error, :unexpected_message}] = actions
    end

    test "multi-fabric: two fabrics can each accept CASE" do
      # Create handler with fabric 1
      {pub1, priv1} = MatterEx.Crypto.Certificate.generate_keypair()
      noc1 = MatterEx.CASE.Messages.encode_noc(1, 1, pub1)
      ipk1 = :crypto.strong_rand_bytes(16)

      handler = MessageHandler.new(
        device: TestLight,
        passcode: @passcode,
        salt: @salt,
        iterations: @iterations,
        local_session_id: 1,
        noc: noc1,
        private_key: priv1,
        ipk: ipk1,
        node_id: 1,
        fabric_id: 1,
        fabric_index: 1
      )

      # Add fabric 2
      {pub2, priv2} = MatterEx.Crypto.Certificate.generate_keypair()
      noc2 = MatterEx.CASE.Messages.encode_noc(10, 2, pub2)
      ipk2 = :crypto.strong_rand_bytes(16)

      handler = MessageHandler.update_case(handler, [
        noc: noc2, private_key: priv2, ipk: ipk2,
        node_id: 10, fabric_id: 2, fabric_index: 2
      ])

      assert map_size(handler.case_states) == 2

      # Initiator for fabric 1
      {init_pub1, init_priv1} = MatterEx.Crypto.Certificate.generate_keypair()
      init_noc1 = MatterEx.CASE.Messages.encode_noc(2, 1, init_pub1)

      init1 = MatterEx.CASE.new_initiator(
        noc: init_noc1, private_key: init_priv1, ipk: ipk1,
        node_id: 2, fabric_id: 1, local_session_id: 100,
        peer_node_id: 1, peer_fabric_id: 1
      )

      # Run CASE handshake for fabric 1
      {:send, :case_sigma1, sigma1, init1} = MatterEx.CASE.initiate(init1)
      frame = build_case_frame(:case_sigma1, sigma1, 10, 0)
      {[{:send, sigma2_frame}], handler} = MessageHandler.handle_frame(handler, frame)

      {:ok, sigma2_msg} = MessageCodec.decode(sigma2_frame)
      {:send, :case_sigma3, sigma3, _init1} =
        MatterEx.CASE.handle(init1, :case_sigma2, sigma2_msg.proto.payload)

      frame = build_case_frame(:case_sigma3, sigma3, 10, 1)
      {actions, handler} = MessageHandler.handle_frame(handler, frame)
      [{:send, _sr}, {:session_established, sid1}] = actions
      assert Map.has_key?(handler.sessions, sid1)

      # Initiator for fabric 2
      {init_pub2, init_priv2} = MatterEx.Crypto.Certificate.generate_keypair()
      init_noc2 = MatterEx.CASE.Messages.encode_noc(20, 2, init_pub2)

      init2 = MatterEx.CASE.new_initiator(
        noc: init_noc2, private_key: init_priv2, ipk: ipk2,
        node_id: 20, fabric_id: 2, local_session_id: 200,
        peer_node_id: 10, peer_fabric_id: 2
      )

      # Run CASE handshake for fabric 2
      {:send, :case_sigma1, sigma1_2, init2} = MatterEx.CASE.initiate(init2)
      frame = build_case_frame(:case_sigma1, sigma1_2, 20, 2)
      {[{:send, sigma2_frame2}], handler} = MessageHandler.handle_frame(handler, frame)

      {:ok, sigma2_msg2} = MessageCodec.decode(sigma2_frame2)
      {:send, :case_sigma3, sigma3_2, _init2} =
        MatterEx.CASE.handle(init2, :case_sigma2, sigma2_msg2.proto.payload)

      frame = build_case_frame(:case_sigma3, sigma3_2, 20, 3)
      {actions2, handler} = MessageHandler.handle_frame(handler, frame)
      [{:send, _sr2}, {:session_established, sid2}] = actions2
      assert Map.has_key?(handler.sessions, sid2)

      # Both sessions exist with different IDs
      assert sid1 != sid2
      assert map_size(handler.sessions) >= 2
    end
  end

  # ── Commissioning flow ──────────────────────────────────────────

  describe "commissioning flow" do
    setup do
      start_supervised!(TestLight)
      start_supervised!({MatterEx.Commissioning, name: MatterEx.Commissioning})
      :ok
    end

    defp send_invoke(handler, session, endpoint, cluster_id, command_id, fields) do
      invoke_req = IM.encode(%IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: endpoint, cluster: cluster_id, command: command_id}, fields: fields}
        ]
      })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :invoke_request),
        exchange_id: :rand.uniform(65534),
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: invoke_req
      }

      {frame, session} = SecureChannel.seal(session, proto)
      {actions, handler} = MessageHandler.handle_frame(handler, frame)

      send_actions = Enum.filter(actions, &match?({:send, _}, &1))
      [{:send, resp_frame}] = send_actions

      {:ok, msg, session} = SecureChannel.open(session, resp_frame)
      {:ok, response} = IM.decode(:invoke_response, msg.proto.payload)

      {response, session, handler}
    end

    test "full PASE → commission → CASE credentials available" do
      handler = new_handler(device: TestLight)
      {comm_session, handler} = run_pase_handshake(handler)

      # 1. ArmFailSafe (endpoint 0, cluster 0x0030, command 0x00)
      {response, comm_session, handler} =
        send_invoke(handler, comm_session, 0, 0x0030, 0x00,
          %{0 => {:uint, 900}, 1 => {:uint, 1}})

      [{:command, arm_resp}] = response.invoke_responses
      assert arm_resp.fields[0] == 0  # ErrorCode=OK

      # 2. CSRRequest (endpoint 0, cluster 0x003E, command 0x04)
      csr_nonce = :crypto.strong_rand_bytes(32)
      {response, comm_session, handler} =
        send_invoke(handler, comm_session, 0, 0x003E, 0x04,
          %{0 => {:bytes, csr_nonce}})

      [{:command, cmd_data}] = response.invoke_responses
      nocsr_elements = cmd_data.fields[0]

      # Decode NOCSR to get the public key from the PKCS#10 CSR
      nocsr_decoded = MatterEx.TLV.decode(nocsr_elements)
      pub_key = MatterEx.Crypto.Certificate.pubkey_from_csr(nocsr_decoded[1])

      # 3. AddTrustedRootCert (endpoint 0, cluster 0x003E, command 0x0B)
      root_cert = :crypto.strong_rand_bytes(200)
      {_response, comm_session, handler} =
        send_invoke(handler, comm_session, 0, 0x003E, 0x0B,
          %{0 => {:bytes, root_cert}})

      # 4. AddNOC (endpoint 0, cluster 0x003E, command 0x06)
      noc = MatterEx.CASE.Messages.encode_noc(42, 1, pub_key)
      ipk = :crypto.strong_rand_bytes(16)
      {response, comm_session, handler} =
        send_invoke(handler, comm_session, 0, 0x003E, 0x06,
          %{0 => {:bytes, noc}, 2 => {:bytes, ipk}, 3 => {:uint, 112233}, 4 => {:uint, 0xFFF1}})

      [{:command, noc_resp}] = response.invoke_responses
      assert noc_resp.fields[0] == 0  # StatusCode=Success

      # 5. CommissioningComplete (endpoint 0, cluster 0x0030, command 0x04)
      {response, _comm_session, handler} =
        send_invoke(handler, comm_session, 0, 0x0030, 0x04, nil)

      [{:command, cc_resp}] = response.invoke_responses
      assert cc_resp.fields[0] == 0  # Success

      # Commissioning Agent should now have credentials
      assert MatterEx.Commissioning.commissioned?()
      creds = MatterEx.Commissioning.get_credentials()
      assert creds.node_id == 42
      assert creds.fabric_id == 1

      # Update handler with CASE credentials
      handler = MessageHandler.update_case(handler, Keyword.new(creds))
      assert map_size(handler.case_states) > 0
      assert handler.case_states[1].node_id == 42
    end

    test "commissioned credentials produce valid CASE session" do
      handler = new_handler(device: TestLight)
      {comm_session, handler} = run_pase_handshake(handler)

      # Quick commission: CSRRequest → AddRoot → AddNOC → CommissioningComplete
      {_response, comm_session, handler} =
        send_invoke(handler, comm_session, 0, 0x0030, 0x00, %{0 => {:uint, 900}, 1 => {:uint, 0}})

      csr_nonce = :crypto.strong_rand_bytes(32)
      {response, comm_session, handler} =
        send_invoke(handler, comm_session, 0, 0x003E, 0x04, %{0 => {:bytes, csr_nonce}})

      [{:command, cmd_data}] = response.invoke_responses
      nocsr_decoded = MatterEx.TLV.decode(cmd_data.fields[0])
      pub_key = MatterEx.Crypto.Certificate.pubkey_from_csr(nocsr_decoded[1])

      root_cert = :crypto.strong_rand_bytes(200)
      {_response, comm_session, handler} =
        send_invoke(handler, comm_session, 0, 0x003E, 0x0B, %{0 => {:bytes, root_cert}})

      ipk = :crypto.strong_rand_bytes(16)
      noc = MatterEx.CASE.Messages.encode_noc(42, 1, pub_key)
      {_response, comm_session, handler} =
        send_invoke(handler, comm_session, 0, 0x003E, 0x06,
          %{0 => {:bytes, noc}, 2 => {:bytes, ipk}, 3 => {:uint, 112233}, 4 => {:uint, 0xFFF1}})

      {_response, _comm_session, handler} =
        send_invoke(handler, comm_session, 0, 0x0030, 0x04, nil)

      # Update CASE from commissioning credentials
      creds = MatterEx.Commissioning.get_credentials()
      handler = MessageHandler.update_case(handler, Keyword.new(creds))

      # Now do a CASE handshake with the commissioned credentials
      {init_pub, init_priv} = MatterEx.Crypto.Certificate.generate_keypair()
      init_noc = MatterEx.CASE.Messages.encode_noc(2, 1, init_pub)

      init = MatterEx.CASE.new_initiator(
        noc: init_noc,
        private_key: init_priv,
        ipk: ipk,
        node_id: 2,
        fabric_id: 1,
        local_session_id: 200,
        peer_node_id: 42,
        peer_fabric_id: 1
      )

      # Sigma1
      {:send, :case_sigma1, sigma1_payload, init} = MatterEx.CASE.initiate(init)
      frame = build_pase_frame(:case_sigma1, sigma1_payload, 50, counter: 100)
      {actions, handler} = MessageHandler.handle_frame(handler, frame)
      [{:send, sigma2_frame}] = actions

      # Sigma2 → Sigma3
      {:ok, sigma2_msg} = MessageCodec.decode(sigma2_frame)
      {:send, :case_sigma3, sigma3_payload, _init} =
        MatterEx.CASE.handle(init, :case_sigma2, sigma2_msg.proto.payload)

      frame = build_pase_frame(:case_sigma3, sigma3_payload, 50, counter: 101)
      {actions, handler} = MessageHandler.handle_frame(handler, frame)

      [{:send, _sr_frame}, {:session_established, case_session_id}] = actions
      assert Map.has_key?(handler.sessions, case_session_id)

      # Verify the session node_id matches commissioned id
      session = handler.sessions[case_session_id].session
      assert session.local_node_id == 42
    end
  end

  # ── ACL enforcement ─────────────────────────────────────────────

  describe "ACL enforcement" do
    setup do
      start_supervised!(TestLight)
      :ok
    end

    test "PASE session bypasses ACL (empty ACL still allows read)" do
      handler = new_handler(device: TestLight)
      {comm_session, handler} = run_pase_handshake(handler)

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

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      [{:send, resp_frame} | _] = actions
      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, resp_frame)
      {:ok, report} = IM.decode(:report_data, msg.proto.payload)

      # PASE bypasses ACL — should get data, not status error
      assert [{:data, data}] = report.attribute_reports
      assert data.value == false
    end

    test "CASE session denied when no ACL entries" do
      {handler, ipk} = new_handler_with_case(device: TestLight)
      {init_session, handler, _session_id} = run_case_handshake(handler, ipk)

      # No ACL entries seeded — CASE read should be denied
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

      {frame, init_session} = SecureChannel.seal(init_session, proto)
      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      [{:send, resp_frame} | _] = actions
      {:ok, msg, _init_session} = SecureChannel.open(init_session, resp_frame)
      {:ok, report} = IM.decode(:report_data, msg.proto.payload)

      # CASE without ACL → denied (status error, not data)
      assert [{:status, status}] = report.attribute_reports
      assert status.status == MatterEx.IM.Status.status_code(:unsupported_access)
    end

    test "CASE session allowed with admin ACL entry" do
      {handler, ipk} = new_handler_with_case(device: TestLight)
      {init_session, handler, _session_id} = run_case_handshake(handler, ipk)

      # Seed admin ACL for the CASE initiator (node_id=2)
      seed_acl(TestLight, 2)

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

      {frame, init_session} = SecureChannel.seal(init_session, proto)
      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      [{:send, resp_frame} | _] = actions
      {:ok, msg, _init_session} = SecureChannel.open(init_session, resp_frame)
      {:ok, report} = IM.decode(:report_data, msg.proto.payload)

      # Admin ACL → allowed (data, not status error)
      assert [{:data, data}] = report.attribute_reports
      assert data.value == false
    end

    test "CASE session with View privilege can read but not invoke" do
      {handler, ipk} = new_handler_with_case(device: TestLight)
      {init_session, handler, _session_id} = run_case_handshake(handler, ipk)

      # Seed View-only ACL (privilege=1) for initiator
      seed_acl(TestLight, 2, 1)

      # Read should succeed (requires View)
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

      {frame, init_session} = SecureChannel.seal(init_session, proto)
      {actions, handler} = MessageHandler.handle_frame(handler, frame)

      [{:send, resp_frame} | _] = actions
      {:ok, msg, init_session} = SecureChannel.open(init_session, resp_frame)
      {:ok, report} = IM.decode(:report_data, msg.proto.payload)
      assert [{:data, _}] = report.attribute_reports

      # Invoke should be denied (requires Operate, we only have View)
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

      {frame2, init_session} = SecureChannel.seal(init_session, proto2)
      {actions2, _handler} = MessageHandler.handle_frame(handler, frame2)

      [{:send, resp_frame2} | _] = actions2
      {:ok, msg2, _init_session} = SecureChannel.open(init_session, resp_frame2)
      {:ok, invoke_resp} = IM.decode(:invoke_response, msg2.proto.payload)

      [{:status, status}] = invoke_resp.invoke_responses
      assert status.status == MatterEx.IM.Status.status_code(:unsupported_access)
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

  # ── Group Messaging ──────────────────────────────────────────────

  describe "group messaging" do
    setup do
      start_supervised!(TestLight)
      handler = new_handler(device: TestLight)

      # Create group key entry
      epoch_key = :crypto.strong_rand_bytes(16)
      alias MatterEx.Crypto.GroupKey
      op_key = GroupKey.operational_key(epoch_key)
      enc_key = GroupKey.encryption_key(op_key, 100)
      session_id = GroupKey.session_id(op_key)

      group_entry = %{group_id: 100, session_id: session_id, encrypt_key: enc_key}
      handler = MessageHandler.update_group_keys(handler, [group_entry])

      %{handler: handler, enc_key: enc_key, session_id: session_id, group_id: 100}
    end

    test "update_group_keys stores entries indexed by session_id",
         %{handler: handler, session_id: session_id, group_id: group_id} do
      assert Map.has_key?(handler.group_keys, session_id)
      assert handler.group_keys[session_id].group_id == group_id
    end

    test "group message is decrypted and processed (no reply)",
         %{handler: handler, enc_key: enc_key, session_id: session_id} do
      # Build a group invoke_request (toggle OnOff on endpoint 1)
      invoke_req = %IM.InvokeRequest{
        invoke_requests: [%{path: %{endpoint: 1, cluster: 0x0006, command: 2}, fields: nil}]
      }
      payload = IM.encode(invoke_req)

      frame = build_group_frame(session_id, enc_key, :invoke_request, payload, 42)

      {actions, _handler} = MessageHandler.handle_frame(handler, frame)

      # No reply for group messages
      assert actions == []
    end

    test "group message for unknown session returns error",
         %{handler: handler, enc_key: enc_key} do
      invoke_req = %IM.InvokeRequest{
        invoke_requests: [%{path: %{endpoint: 1, cluster: 0x0006, command: 2}, fields: nil}]
      }
      payload = IM.encode(invoke_req)

      # Use a session_id that doesn't match any group key
      frame = build_group_frame(99999, enc_key, :invoke_request, payload, 42)

      {actions, _handler} = MessageHandler.handle_frame(handler, frame)
      assert [{:error, :unknown_group_session}] = actions
    end

    test "group message with wrong key fails decryption",
         %{handler: handler, session_id: session_id} do
      invoke_req = %IM.InvokeRequest{
        invoke_requests: [%{path: %{endpoint: 1, cluster: 0x0006, command: 2}, fields: nil}]
      }
      payload = IM.encode(invoke_req)

      # Use a different encryption key
      wrong_key = :crypto.strong_rand_bytes(16)
      frame = build_group_frame(session_id, wrong_key, :invoke_request, payload, 42)

      {actions, _handler} = MessageHandler.handle_frame(handler, frame)
      assert [{:error, :authentication_failed}] = actions
    end

    test "group write_request is processed without reply",
         %{handler: handler, enc_key: enc_key, session_id: session_id} do
      # Seed ACL for group auth_mode (auth_mode: 3)
      acl_name = TestLight.__process_name__(0, :access_control)
      group_acl = %{
        privilege: 3,
        auth_mode: 3,
        subjects: nil,
        targets: nil,
        fabric_index: 0
      }
      GenServer.call(acl_name, {:write_attribute, :acl, [group_acl]})

      write_req = %IM.WriteRequest{
        write_requests: [%{path: %{endpoint: 1, cluster: 0x0006, attribute: 0}, value: {:bool, true}, version: 0}]
      }
      payload = IM.encode(write_req)

      frame = build_group_frame(session_id, enc_key, :write_request, payload, 43)

      {actions, _handler} = MessageHandler.handle_frame(handler, frame)
      assert actions == []
    end
  end

  # ── Group frame builder ──────────────────────────────────────────

  defp build_group_frame(session_id, encrypt_key, opcode_name, payload, counter) do
    header = %Header{
      session_id: session_id,
      message_counter: counter,
      source_node_id: 42,
      dest_group_id: 100,
      privacy: false,
      session_type: :group
    }

    opcode_num = ProtocolID.opcode(:interaction_model, opcode_name)

    proto = %ProtoHeader{
      initiator: true,
      opcode: opcode_num,
      exchange_id: 1,
      protocol_id: ProtocolID.protocol_id(:interaction_model),
      payload: payload
    }

    nonce = MessageCodec.build_nonce(
      encode_group_security_flags(header),
      counter,
      42
    )

    IO.iodata_to_binary(MessageCodec.encode_encrypted(header, proto, encrypt_key, nonce))
  end

  defp encode_group_security_flags(%Header{} = h) do
    import Bitwise
    p = if h.privacy, do: 0x80, else: 0
    c = if h.control_message, do: 0x40, else: 0
    st = if h.session_type == :group, do: 1, else: 0
    p ||| c ||| st
  end
end
