defmodule Matterlix.NodeTest do
  use ExUnit.Case

  alias Matterlix.{PASE, SecureChannel}
  alias Matterlix.IM
  alias Matterlix.Protocol.{MessageCodec, ProtocolID}
  alias Matterlix.Protocol.MessageCodec.{Header, ProtoHeader}

  @passcode 20202021
  @salt :crypto.strong_rand_bytes(32)
  @iterations 1000

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

  setup do
    start_supervised!(TestLight)

    node = start_supervised!({
      Matterlix.Node,
      device: TestLight,
      passcode: @passcode,
      salt: @salt,
      iterations: @iterations,
      port: 0
    })

    port = Matterlix.Node.port(node)
    {:ok, client} = :gen_udp.open(0, [:binary, {:active, true}])

    on_exit(fn -> :gen_udp.close(client) end)

    %{node: node, port: port, client: client}
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp send_and_receive(client, port, data) do
    :ok = :gen_udp.send(client, ~c"127.0.0.1", port, data)

    receive do
      {:udp, ^client, _ip, _port, response} -> response
    after
      2000 -> flunk("No UDP response received within 2s")
    end
  end

  defp build_pase_frame(opcode_name, payload, exchange_id, counter) do
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

  # Run a full PASE handshake over UDP, returning the commissioner session
  defp run_pase_over_udp(client, port) do
    comm = PASE.new_commissioner(passcode: @passcode, local_session_id: 2)
    exchange_id = 1

    # Step 1: PBKDFParamRequest
    {:send, :pbkdf_param_request, req_payload, comm} = PASE.initiate(comm)
    frame = build_pase_frame(:pbkdf_param_request, req_payload, exchange_id, 0)
    resp = send_and_receive(client, port, frame)

    {:ok, resp_msg} = MessageCodec.decode(resp)
    {:send, :pase_pake1, pake1_payload, comm} =
      PASE.handle(comm, :pbkdf_param_response, resp_msg.proto.payload)

    # Step 2: Pake1
    frame = build_pase_frame(:pase_pake1, pake1_payload, exchange_id, 1)
    resp = send_and_receive(client, port, frame)

    {:ok, pake2_msg} = MessageCodec.decode(resp)
    {:send, :pase_pake3, pake3_payload, comm} =
      PASE.handle(comm, :pase_pake2, pake2_msg.proto.payload)

    # Step 3: Pake3
    frame = build_pase_frame(:pase_pake3, pake3_payload, exchange_id, 2)
    resp = send_and_receive(client, port, frame)

    {:ok, sr_msg} = MessageCodec.decode(resp)
    {:established, comm_session, _comm} =
      PASE.handle(comm, :status_report, sr_msg.proto.payload)

    comm_session
  end

  # ── Basic connectivity ──────────────────────────────────────────

  describe "basic connectivity" do
    test "node starts and listens on port", %{port: port} do
      assert port > 0
    end

    test "port/1 returns assigned port", %{node: node, port: port} do
      assert Matterlix.Node.port(node) == port
    end
  end

  # ── PASE over UDP ───────────────────────────────────────────────

  describe "PASE over UDP" do
    test "full PASE handshake over UDP produces session", %{client: client, port: port} do
      comm_session = run_pase_over_udp(client, port)

      assert comm_session.local_session_id == 2
      assert byte_size(comm_session.encrypt_key) == 16
      assert byte_size(comm_session.decrypt_key) == 16
    end

    test "PBKDFParamRequest returns valid response", %{client: client, port: port} do
      comm = PASE.new_commissioner(passcode: @passcode, local_session_id: 2)
      {:send, :pbkdf_param_request, req_payload, _comm} = PASE.initiate(comm)

      frame = build_pase_frame(:pbkdf_param_request, req_payload, 1, 0)
      resp = send_and_receive(client, port, frame)

      {:ok, msg} = MessageCodec.decode(resp)
      assert msg.header.session_id == 0
      assert msg.proto.opcode == ProtocolID.opcode(:secure_channel, :pbkdf_param_response)
      assert msg.proto.exchange_id == 1
      assert msg.proto.initiator == false
    end
  end

  # ── Encrypted IM over UDP ──────────────────────────────────────

  describe "encrypted IM over UDP" do
    test "ReadRequest returns ReportData", %{client: client, port: port} do
      comm_session = run_pase_over_udp(client, port)

      # Build encrypted ReadRequest
      read_req = IM.encode(%IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        fabric_filtered: true
      })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :read_request),
        exchange_id: 10,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: read_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      resp = send_and_receive(client, port, frame)

      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, resp)
      assert msg.proto.opcode == ProtocolID.opcode(:interaction_model, :report_data)

      {:ok, report} = IM.decode(:report_data, msg.proto.payload)
      assert %IM.ReportData{} = report
      assert length(report.attribute_reports) == 1
    end

    test "full round trip: read, invoke on, read again", %{client: client, port: port} do
      comm_session = run_pase_over_udp(client, port)

      # Read on_off (should be false)
      read_req = IM.encode(%IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        fabric_filtered: true
      })

      proto = %ProtoHeader{
        initiator: true, needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :read_request),
        exchange_id: 10, protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: read_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      resp = send_and_receive(client, port, frame)
      {:ok, msg, comm_session} = SecureChannel.open(comm_session, resp)
      {:ok, report} = IM.decode(:report_data, msg.proto.payload)
      [{:data, data}] = report.attribute_reports
      assert data.value == false

      # Invoke "on" command
      invoke_req = IM.encode(%IM.InvokeRequest{
        invoke_requests: [%{path: %{endpoint: 1, cluster: 6, command: 1}, fields: nil}]
      })

      proto2 = %ProtoHeader{
        initiator: true, needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :invoke_request),
        exchange_id: 11, protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: invoke_req
      }

      {frame2, comm_session} = SecureChannel.seal(comm_session, proto2)
      resp2 = send_and_receive(client, port, frame2)
      {:ok, _msg2, comm_session} = SecureChannel.open(comm_session, resp2)

      # Read again (should be true now)
      read_req2 = IM.encode(%IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        fabric_filtered: true
      })

      proto3 = %ProtoHeader{
        initiator: true, needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :read_request),
        exchange_id: 12, protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: read_req2
      }

      {frame3, comm_session} = SecureChannel.seal(comm_session, proto3)
      resp3 = send_and_receive(client, port, frame3)
      {:ok, msg3, _comm_session} = SecureChannel.open(comm_session, resp3)
      {:ok, report3} = IM.decode(:report_data, msg3.proto.payload)
      [{:data, data3}] = report3.attribute_reports
      assert data3.value == true
    end
  end

  # ── Subscribe over UDP ─────────────────────────────────────────

  describe "subscribe over UDP" do
    test "SubscribeRequest → encrypted SubscribeResponse", %{client: client, port: port} do
      comm_session = run_pase_over_udp(client, port)

      sub_req = IM.encode(%IM.SubscribeRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        min_interval: 0,
        max_interval: 60
      })

      proto = %ProtoHeader{
        initiator: true, needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :subscribe_request),
        exchange_id: 10, protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: sub_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      resp = send_and_receive(client, port, frame)

      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, resp)
      assert msg.proto.opcode == ProtocolID.opcode(:interaction_model, :subscribe_response)

      {:ok, sub_resp} = IM.decode(:subscribe_response, msg.proto.payload)
      assert sub_resp.subscription_id == 1
      assert sub_resp.max_interval == 60
    end
  end

  # ── Error handling ──────────────────────────────────────────────

  describe "error handling" do
    test "malformed frame does not crash node", %{client: client, port: port, node: node} do
      :ok = :gen_udp.send(client, ~c"127.0.0.1", port, <<0, 1, 2, 3>>)

      # Give the node a moment to process
      Process.sleep(50)

      # Node is still alive
      assert Process.alive?(node)
    end
  end
end
