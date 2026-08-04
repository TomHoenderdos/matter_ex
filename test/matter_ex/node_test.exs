defmodule MatterEx.NodeTest do
  use ExUnit.Case

  alias MatterEx.IM
  alias MatterEx.{PASE, SecureChannel}
  alias MatterEx.Protocol.{MessageCodec, ProtocolID}
  alias MatterEx.Protocol.MessageCodec.{Header, ProtoHeader}
  alias MatterEx.Transport.TCP, as: TCPFraming

  @passcode 20_202_021
  @salt :crypto.strong_rand_bytes(32)
  @iterations 1000

  defmodule TestLight do
    use MatterEx.Device,
      vendor_name: "TestCo",
      product_name: "TestLight",
      vendor_id: 0xFFF1,
      product_id: 0x8001

    endpoint 1, device_type: 0x0100 do
      cluster(MatterEx.Cluster.OnOff)
    end
  end

  setup do
    start_supervised!(TestLight)

    node =
      start_supervised!({
        MatterEx.Node,
        device: TestLight, passcode: @passcode, salt: @salt, iterations: @iterations, port: 0
      })

    port = MatterEx.Node.port(node)
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

  defp send_and_receive_ipv6(client, port, data) do
    :ok = :gen_udp.send(client, {0, 0, 0, 0, 0, 0, 0, 1}, port, data)

    receive do
      {:udp, ^client, _ip, _port, response} -> response
    after
      2000 -> flunk("No IPv6 UDP response received within 2s")
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

  # Run a full subscribe handshake (PASE → SubscribeRequest → priming ReportData
  # → StatusResponse) and return the decoded SubscribeResponse.
  defp subscribe(client, port, opts) do
    comm_session = run_pase_over_udp(client, port)
    exchange_id = Keyword.get(opts, :exchange_id, 10)

    sub_req =
      IM.encode(%IM.SubscribeRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
        min_interval: Keyword.fetch!(opts, :min_interval),
        max_interval: Keyword.fetch!(opts, :max_interval)
      })

    proto = %ProtoHeader{
      initiator: true,
      needs_ack: true,
      opcode: ProtocolID.opcode(:interaction_model, :subscribe_request),
      exchange_id: exchange_id,
      protocol_id: ProtocolID.protocol_id(:interaction_model),
      payload: sub_req
    }

    {frame, comm_session} = SecureChannel.seal(comm_session, proto)

    {:ok, msg, comm_session} =
      SecureChannel.open(comm_session, send_and_receive(client, port, frame))

    status_proto = %ProtoHeader{
      initiator: true,
      needs_ack: true,
      ack_counter: msg.header.message_counter,
      opcode: ProtocolID.opcode(:interaction_model, :status_response),
      exchange_id: exchange_id,
      protocol_id: ProtocolID.protocol_id(:interaction_model),
      payload: IM.encode(%IM.StatusResponse{status: 0})
    }

    {status_frame, comm_session} = SecureChannel.seal(comm_session, status_proto)

    {:ok, sub_msg, _comm_session} =
      SecureChannel.open(comm_session, send_and_receive(client, port, status_frame))

    {:ok, sub_resp} = IM.decode(:subscribe_response, sub_msg.proto.payload)
    sub_resp
  end

  # TCP helpers

  defp tcp_connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, {:active, true}])
    socket
  end

  # The acceptor is the sole child of the node's linked TCP supervisor.
  defp tcp_acceptor(node) do
    case :sys.get_state(node).tcp_sup do
      nil ->
        nil

      sup ->
        case Supervisor.which_children(sup) do
          [{_id, pid, _type, _mods}] when is_pid(pid) -> pid
          _ -> nil
        end
    end
  end

  # Poll a condition rather than sleeping a fixed amount — a supervisor restart
  # plus re-binding the listen socket has no callback to wait on.
  defp eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.() do
        true
      else
        Process.sleep(20)
        false
      end
    end)
    |> Enum.find(fn ok -> ok or System.monotonic_time(:millisecond) > deadline end)
  end

  defp tcp_send_and_receive(socket, data) do
    framed = TCPFraming.frame(data)
    :ok = :gen_tcp.send(socket, framed)

    receive do
      {:tcp, ^socket, response_data} ->
        {[message], _remaining} = TCPFraming.parse(response_data)
        message
    after
      2000 -> flunk("No TCP response received within 2s")
    end
  end

  defp run_pase_over_tcp(tcp_socket) do
    comm = PASE.new_commissioner(passcode: @passcode, local_session_id: 2)
    exchange_id = 1

    {:send, :pbkdf_param_request, req_payload, comm} = PASE.initiate(comm)
    frame = build_pase_frame(:pbkdf_param_request, req_payload, exchange_id, 0)
    resp = tcp_send_and_receive(tcp_socket, frame)

    {:ok, resp_msg} = MessageCodec.decode(resp)

    {:send, :pase_pake1, pake1_payload, comm} =
      PASE.handle(comm, :pbkdf_param_response, resp_msg.proto.payload)

    frame = build_pase_frame(:pase_pake1, pake1_payload, exchange_id, 1)
    resp = tcp_send_and_receive(tcp_socket, frame)

    {:ok, pake2_msg} = MessageCodec.decode(resp)

    {:send, :pase_pake3, pake3_payload, comm} =
      PASE.handle(comm, :pase_pake2, pake2_msg.proto.payload)

    frame = build_pase_frame(:pase_pake3, pake3_payload, exchange_id, 2)
    resp = tcp_send_and_receive(tcp_socket, frame)

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
      assert MatterEx.Node.port(node) == port
    end

    test "TCP listener accepts connections", %{port: port} do
      socket = tcp_connect(port)
      # Connection established — no crash
      :gen_tcp.close(socket)
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

    test "accepts a new PASE handshake after one is established", %{client: client, port: port} do
      first = run_pase_over_udp(client, port)
      second = run_pase_over_udp(client, port)

      assert first.local_session_id == 2
      assert second.local_session_id == 2
      assert first.decrypt_key != second.decrypt_key
    end

    test "responds on IPv6 UDP socket", %{port: port} do
      {:ok, client} = :gen_udp.open(0, [:binary, {:active, true}, :inet6])
      on_exit(fn -> :gen_udp.close(client) end)

      comm = PASE.new_commissioner(passcode: @passcode, local_session_id: 2)
      {:send, :pbkdf_param_request, req_payload, _comm} = PASE.initiate(comm)

      frame = build_pase_frame(:pbkdf_param_request, req_payload, 1, 0)
      resp = send_and_receive_ipv6(client, port, frame)

      {:ok, msg} = MessageCodec.decode(resp)
      assert msg.proto.opcode == ProtocolID.opcode(:secure_channel, :pbkdf_param_response)
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

  # ── PASE over TCP ───────────────────────────────────────────────

  describe "PASE over TCP" do
    test "full PASE handshake over TCP produces session", %{port: port} do
      tcp_socket = tcp_connect(port)
      # Small delay for accept
      Process.sleep(50)

      comm_session = run_pase_over_tcp(tcp_socket)

      assert comm_session.local_session_id == 2
      assert byte_size(comm_session.encrypt_key) == 16
      assert byte_size(comm_session.decrypt_key) == 16

      :gen_tcp.close(tcp_socket)
    end

    test "encrypted IM read over TCP", %{port: port} do
      tcp_socket = tcp_connect(port)
      Process.sleep(50)

      comm_session = run_pase_over_tcp(tcp_socket)

      read_req =
        IM.encode(%IM.ReadRequest{
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
      resp = tcp_send_and_receive(tcp_socket, frame)

      {:ok, msg, _comm_session} = SecureChannel.open(comm_session, resp)
      assert msg.proto.opcode == ProtocolID.opcode(:interaction_model, :report_data)

      {:ok, report} = IM.decode(:report_data, msg.proto.payload)
      assert [{:data, data}] = report.attribute_reports
      assert data.value == false

      :gen_tcp.close(tcp_socket)
    end

    test "full round trip over TCP: read, invoke, read", %{port: port} do
      tcp_socket = tcp_connect(port)
      Process.sleep(50)

      comm_session = run_pase_over_tcp(tcp_socket)

      # Read on_off (false)
      read_req =
        IM.encode(%IM.ReadRequest{
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
      resp = tcp_send_and_receive(tcp_socket, frame)
      {:ok, msg, comm_session} = SecureChannel.open(comm_session, resp)
      {:ok, report} = IM.decode(:report_data, msg.proto.payload)
      [{:data, data}] = report.attribute_reports
      assert data.value == false

      # Invoke "on"
      invoke_req =
        IM.encode(%IM.InvokeRequest{
          invoke_requests: [%{path: %{endpoint: 1, cluster: 6, command: 1}, fields: nil}]
        })

      proto2 = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :invoke_request),
        exchange_id: 11,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: invoke_req
      }

      {frame2, comm_session} = SecureChannel.seal(comm_session, proto2)
      resp2 = tcp_send_and_receive(tcp_socket, frame2)
      {:ok, _msg2, comm_session} = SecureChannel.open(comm_session, resp2)

      # Read on_off (true)
      read_req2 =
        IM.encode(%IM.ReadRequest{
          attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
          fabric_filtered: true
        })

      proto3 = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :read_request),
        exchange_id: 12,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: read_req2
      }

      {frame3, comm_session} = SecureChannel.seal(comm_session, proto3)
      resp3 = tcp_send_and_receive(tcp_socket, frame3)
      {:ok, msg3, _comm_session} = SecureChannel.open(comm_session, resp3)
      {:ok, report3} = IM.decode(:report_data, msg3.proto.payload)
      [{:data, data3}] = report3.attribute_reports
      assert data3.value == true

      :gen_tcp.close(tcp_socket)
    end
  end

  # ── Encrypted IM over UDP ──────────────────────────────────────

  describe "encrypted IM over UDP" do
    test "ReadRequest returns ReportData", %{client: client, port: port} do
      comm_session = run_pase_over_udp(client, port)

      # Build encrypted ReadRequest
      read_req =
        IM.encode(%IM.ReadRequest{
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
      read_req =
        IM.encode(%IM.ReadRequest{
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
      {:ok, msg, comm_session} = SecureChannel.open(comm_session, resp)
      {:ok, report} = IM.decode(:report_data, msg.proto.payload)
      [{:data, data}] = report.attribute_reports
      assert data.value == false

      # Invoke "on" command
      invoke_req =
        IM.encode(%IM.InvokeRequest{
          invoke_requests: [%{path: %{endpoint: 1, cluster: 6, command: 1}, fields: nil}]
        })

      proto2 = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :invoke_request),
        exchange_id: 11,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: invoke_req
      }

      {frame2, comm_session} = SecureChannel.seal(comm_session, proto2)
      resp2 = send_and_receive(client, port, frame2)
      {:ok, _msg2, comm_session} = SecureChannel.open(comm_session, resp2)

      # Read again (should be true now)
      read_req2 =
        IM.encode(%IM.ReadRequest{
          attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
          fabric_filtered: true
        })

      proto3 = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :read_request),
        exchange_id: 12,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
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
    test "SubscribeRequest → priming ReportData → StatusResponse → SubscribeResponse", %{
      client: client,
      port: port
    } do
      comm_session = run_pase_over_udp(client, port)

      sub_req =
        IM.encode(%IM.SubscribeRequest{
          attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
          min_interval: 0,
          max_interval: 60
        })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :subscribe_request),
        exchange_id: 10,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: sub_req
      }

      # Phase 1: priming ReportData
      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      resp = send_and_receive(client, port, frame)

      {:ok, msg, comm_session} = SecureChannel.open(comm_session, resp)
      assert msg.proto.opcode == ProtocolID.opcode(:interaction_model, :report_data)

      {:ok, report} = IM.decode(:report_data, msg.proto.payload)
      assert report.subscription_id == 1

      # Phase 2: send StatusResponse → receive SubscribeResponse
      status_resp = IM.encode(%IM.StatusResponse{status: 0})

      status_proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        ack_counter: msg.header.message_counter,
        opcode: ProtocolID.opcode(:interaction_model, :status_response),
        exchange_id: 10,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: status_resp
      }

      {status_frame, comm_session} = SecureChannel.seal(comm_session, status_proto)
      sub_resp_raw = send_and_receive(client, port, status_frame)

      {:ok, sub_msg, _comm_session} = SecureChannel.open(comm_session, sub_resp_raw)
      assert sub_msg.proto.opcode == ProtocolID.opcode(:interaction_model, :subscribe_response)

      {:ok, sub_resp} = IM.decode(:subscribe_response, sub_msg.proto.payload)
      assert sub_resp.subscription_id == 1
      assert sub_resp.max_interval == 60
    end

    test "caps the reported max_interval at the node's max_interval_cap", %{
      client: client,
      port: port
    } do
      comm_session = run_pase_over_udp(client, port)

      # Request a 10-minute ceiling; the node (default cap 120s) should hand back 120.
      sub_req =
        IM.encode(%IM.SubscribeRequest{
          attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
          min_interval: 0,
          max_interval: 600
        })

      proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: ProtocolID.opcode(:interaction_model, :subscribe_request),
        exchange_id: 10,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: sub_req
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)

      {:ok, msg, comm_session} =
        SecureChannel.open(comm_session, send_and_receive(client, port, frame))

      status_proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        ack_counter: msg.header.message_counter,
        opcode: ProtocolID.opcode(:interaction_model, :status_response),
        exchange_id: 10,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: IM.encode(%IM.StatusResponse{status: 0})
      }

      {status_frame, comm_session} = SecureChannel.seal(comm_session, status_proto)

      {:ok, sub_msg, _comm_session} =
        SecureChannel.open(comm_session, send_and_receive(client, port, status_frame))

      {:ok, sub_resp} = IM.decode(:subscribe_response, sub_msg.proto.payload)
      assert sub_resp.max_interval == 120
    end

    test "the cap never pushes max_interval below the requested min_interval", %{
      client: client,
      port: port
    } do
      # A controller whose floor is already above the cap. Capping to 120 here
      # would report a MaxInterval below the MinIntervalFloor it asked for —
      # outside the negotiated window, and enough to defeat the throttle:
      # check_subscriptions/1 tests max_interval_elapsed? before throttled?, so
      # the keep-alive would fire every 120s on a subscription that asked to be
      # reported to no more often than every 300s.
      sub_resp = subscribe(client, port, min_interval: 300, max_interval: 600)

      assert sub_resp.max_interval == 300
    end
  end

  # ── Error handling ──────────────────────────────────────────────

  describe "error handling" do
    test "malformed UDP frame does not crash node", %{client: client, port: port, node: node} do
      :ok = :gen_udp.send(client, ~c"127.0.0.1", port, <<0, 1, 2, 3>>)

      # Give the node a moment to process
      Process.sleep(50)

      # Node is still alive
      assert Process.alive?(node)
    end

    test "malformed TCP frame does not crash node", %{port: port, node: node} do
      tcp_socket = tcp_connect(port)
      Process.sleep(50)

      # Send garbage data (valid length prefix but garbage payload)
      :gen_tcp.send(tcp_socket, TCPFraming.frame(<<0, 1, 2, 3>>))
      Process.sleep(50)

      assert Process.alive?(node)
      :gen_tcp.close(tcp_socket)
    end

    test "TCP connection close does not crash node", %{port: port, node: node} do
      tcp_socket = tcp_connect(port)
      Process.sleep(50)
      :gen_tcp.close(tcp_socket)
      Process.sleep(50)

      assert Process.alive?(node)
    end

    test "an acceptor crash restarts the acceptor, not the node", %{port: port, node: node} do
      # The point of giving the acceptor its own crash domain: before, an accept
      # error either exited the loop as :normal — silently accepting nothing ever
      # again — or propagated over the link and took the node down with it.
      acceptor = tcp_acceptor(node)
      ref = Process.monitor(acceptor)

      Process.exit(acceptor, :kill)
      assert_receive {:DOWN, ^ref, :process, ^acceptor, :killed}, 1_000

      assert Process.alive?(node)

      # A new acceptor takes over and TCP still accepts, so the node did not
      # silently lose the transport.
      assert eventually(fn -> tcp_acceptor(node) not in [nil, acceptor] end)

      assert eventually(fn ->
               case :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 100) do
                 {:ok, socket} -> :gen_tcp.close(socket) == :ok
                 {:error, _} -> false
               end
             end)
    end

    test "a peer that vanishes before it is registered does not crash the node", %{node: node} do
      # peername/1 fails for a socket whose peer has already gone. Handing the
      # node an already-closed socket reproduces that deterministically, where
      # racing a real connect-then-reset would not.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, {:active, false}])
      {:ok, {_addr, listen_port}} = :inet.sockname(listen)
      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", listen_port, [:binary])
      {:ok, accepted} = :gen_tcp.accept(listen)
      :gen_tcp.close(client)
      :gen_tcp.close(accepted)

      send(node, {:tcp_accepted, accepted})

      # A round-trip call confirms the message was processed, not merely queued.
      assert MatterEx.Node.port(node) > 0
      assert Process.alive?(node)

      :gen_tcp.close(listen)
    end
  end

  # ── Per-Peer Addressing ────────────────────────────────────────

  describe "per-peer addressing" do
    test "response sent to new peer address after port change", %{client: client, port: port} do
      # Establish session from first client
      comm_session = run_pase_over_udp(client, port)

      # Send an encrypted read from the first client
      read_req = %IM.ReadRequest{attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0}]}
      payload = IM.encode(read_req)

      opcode_num = ProtocolID.opcode(:interaction_model, :read_request)

      proto = %ProtoHeader{
        initiator: true,
        opcode: opcode_num,
        exchange_id: 10,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: payload,
        needs_ack: true,
        ack_counter: nil
      }

      {frame, comm_session} = SecureChannel.seal(comm_session, proto)
      resp = send_and_receive(client, port, frame)

      # Verify response arrives on first client
      {:ok, _msg, _comm_session2} = SecureChannel.open(comm_session, resp)

      # Now send from a SECOND client (different port, simulating address change)
      {:ok, client2} = :gen_udp.open(0, [:binary, {:active, true}])
      on_exit(fn -> :gen_udp.close(client2) end)

      # Send another read from client2 using the same session
      proto2 = %ProtoHeader{
        initiator: true,
        opcode: opcode_num,
        exchange_id: 11,
        protocol_id: ProtocolID.protocol_id(:interaction_model),
        payload: payload,
        needs_ack: true,
        ack_counter: nil
      }

      {frame2, _comm_session} = SecureChannel.seal(comm_session, proto2)
      :ok = :gen_udp.send(client2, ~c"127.0.0.1", port, frame2)

      # Response should arrive on client2, not client1
      receive do
        {:udp, ^client2, _ip, _port, _response} -> :ok
      after
        2000 -> flunk("No response received on new client")
      end
    end
  end
end
