defmodule Matterlix.ExchangeManagerTest do
  use ExUnit.Case, async: true

  alias Matterlix.ExchangeManager
  alias Matterlix.IM
  alias Matterlix.Protocol.MRP
  alias Matterlix.Protocol.MessageCodec.ProtoHeader

  # Mock handler that returns canned IM responses
  @read_response %IM.ReportData{
    attribute_reports: [
      {:data, %{version: 0, path: %{endpoint: 1, cluster: 6, attribute: 0}, value: {:bool, true}}}
    ]
  }

  @write_response %IM.WriteResponse{
    write_responses: [
      %{path: %{endpoint: 1, cluster: 6, attribute: 0}, status: 0, cluster_status: nil}
    ]
  }

  @invoke_response %IM.InvokeResponse{
    invoke_responses: [
      {:status, %{path: %{endpoint: 1, cluster: 6, command: 1}, status: 0, cluster_status: nil}}
    ]
  }

  defp mock_handler(:read_request, %IM.ReadRequest{}), do: @read_response
  defp mock_handler(:write_request, %IM.WriteRequest{}), do: @write_response
  defp mock_handler(:invoke_request, %IM.InvokeRequest{}), do: @invoke_response
  defp mock_handler(:timed_request, %IM.TimedRequest{}), do: %IM.StatusResponse{status: 0}

  defp new_manager do
    ExchangeManager.new(handler: &mock_handler/2)
  end

  defp read_request_proto(exchange_id \\ 1) do
    payload = IM.encode(%IM.ReadRequest{
      attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}],
      fabric_filtered: true
    })

    %ProtoHeader{
      initiator: true,
      needs_ack: true,
      opcode: 0x02,
      exchange_id: exchange_id,
      protocol_id: 0x0001,
      payload: payload
    }
  end

  # ── Exchange lifecycle ──────────────────────────────────────────

  describe "exchange lifecycle" do
    test "incoming IM request opens and closes exchange" do
      mgr = new_manager()
      proto = read_request_proto(42)

      {actions, mgr} = ExchangeManager.handle_message(mgr, proto, 100)

      # Reply action produced
      assert [{:reply, reply}, {:schedule_mrp, 42, 0, _timeout}] = actions
      assert reply.exchange_id == 42

      # Exchange is closed after response (only MRP pending remains)
      assert mgr.exchanges == %{}
    end

    test "multiple concurrent exchanges with different IDs" do
      mgr = new_manager()

      proto1 = read_request_proto(1)
      proto2 = read_request_proto(2)
      proto3 = read_request_proto(3)

      {_actions1, mgr} = ExchangeManager.handle_message(mgr, proto1, 100)
      {_actions2, mgr} = ExchangeManager.handle_message(mgr, proto2, 101)
      {_actions3, mgr} = ExchangeManager.handle_message(mgr, proto3, 102)

      # All exchanges closed, but MRP tracks all three
      assert mgr.exchanges == %{}
      assert MRP.pending?(mgr.mrp, 1)
      assert MRP.pending?(mgr.mrp, 2)
      assert MRP.pending?(mgr.mrp, 3)
    end
  end

  # ── ACK management ─────────────────────────────────────────────

  describe "ACK management" do
    test "response piggybacks ACK when incoming has needs_ack" do
      mgr = new_manager()
      proto = read_request_proto()
      proto = %{proto | needs_ack: true}

      {actions, _mgr} = ExchangeManager.handle_message(mgr, proto, 42)

      [{:reply, reply}, _mrp] = actions
      assert reply.ack_counter == 42
    end

    test "no piggyback ACK when incoming does not need ACK" do
      mgr = new_manager()
      proto = %{read_request_proto() | needs_ack: false}

      {actions, _mgr} = ExchangeManager.handle_message(mgr, proto, 42)

      [{:reply, reply}, _mrp] = actions
      assert reply.ack_counter == nil
    end

    test "incoming standalone ACK clears MRP pending" do
      mgr = new_manager()
      proto = read_request_proto(5)

      # Send a reply (which gets recorded in MRP)
      {_actions, mgr} = ExchangeManager.handle_message(mgr, proto, 100)
      assert MRP.pending?(mgr.mrp, 5)

      # Receive standalone ACK for exchange 5
      ack_proto = %ProtoHeader{
        initiator: true,
        opcode: 0x10,
        exchange_id: 5,
        protocol_id: 0x0000,
        payload: <<>>
      }

      {actions, mgr} = ExchangeManager.handle_message(mgr, ack_proto, 101)
      assert actions == []
      refute MRP.pending?(mgr.mrp, 5)
    end

    test "standalone ACK for unknown exchange is ignored" do
      mgr = new_manager()

      ack_proto = %ProtoHeader{
        initiator: true,
        opcode: 0x10,
        exchange_id: 999,
        protocol_id: 0x0000,
        payload: <<>>
      }

      {actions, _mgr} = ExchangeManager.handle_message(mgr, ack_proto, 100)
      assert actions == []
    end
  end

  # ── MRP integration ────────────────────────────────────────────

  describe "MRP integration" do
    test "reliable response recorded in MRP with schedule action" do
      mgr = new_manager()
      proto = read_request_proto(7)

      {actions, mgr} = ExchangeManager.handle_message(mgr, proto, 100)

      assert [{:reply, _reply}, {:schedule_mrp, 7, 0, timeout}] = actions
      assert timeout > 0
      assert MRP.pending?(mgr.mrp, 7)
    end

    test "handle_timeout returns retransmit" do
      mgr = new_manager()
      proto = read_request_proto(7)

      {_actions, mgr} = ExchangeManager.handle_message(mgr, proto, 100)

      assert {:retransmit, retransmit_proto, _mgr} =
        ExchangeManager.handle_timeout(mgr, 7, 0)

      assert retransmit_proto.exchange_id == 7
      assert retransmit_proto.opcode == 0x05  # report_data
    end

    test "handle_timeout gives up after max retransmissions" do
      mgr = new_manager()
      proto = read_request_proto(7)
      {_actions, mgr} = ExchangeManager.handle_message(mgr, proto, 100)

      # Walk through retransmissions: attempt 0→1→2→3, then 4 gives up
      # MRP.max_transmissions() == 5 (1 original + 4 retries)
      mgr =
        Enum.reduce(0..3, mgr, fn attempt, acc ->
          {:retransmit, _proto, acc} = ExchangeManager.handle_timeout(acc, 7, attempt)
          acc
        end)

      assert {:give_up, 7, mgr} = ExchangeManager.handle_timeout(mgr, 7, 4)
      refute MRP.pending?(mgr.mrp, 7)
    end

    test "handle_timeout returns already_acked when exchange was ACKed" do
      mgr = new_manager()
      proto = read_request_proto(7)
      {_actions, mgr} = ExchangeManager.handle_message(mgr, proto, 100)

      # ACK the exchange
      ack_proto = %ProtoHeader{
        initiator: true, opcode: 0x10, exchange_id: 7,
        protocol_id: 0x0000, payload: <<>>
      }
      {_, mgr} = ExchangeManager.handle_message(mgr, ack_proto, 101)

      assert {:already_acked, _mgr} = ExchangeManager.handle_timeout(mgr, 7, 0)
    end
  end

  # ── IM dispatch ─────────────────────────────────────────────────

  describe "IM dispatch" do
    test "ReadRequest → ReportData" do
      mgr = new_manager()
      proto = read_request_proto()

      {[{:reply, reply}, _mrp], _mgr} = ExchangeManager.handle_message(mgr, proto, 100)

      assert reply.opcode == 0x05  # report_data
      assert reply.protocol_id == 0x0001
      assert reply.exchange_id == 1
      assert reply.initiator == false
      assert reply.needs_ack == true

      # Decode the reply payload to verify it's a valid ReportData
      assert {:ok, %IM.ReportData{}} = IM.decode(:report_data, reply.payload)
    end

    test "WriteRequest → WriteResponse" do
      mgr = new_manager()

      payload = IM.encode(%IM.WriteRequest{
        write_requests: [
          %{version: 0, path: %{endpoint: 1, cluster: 6, attribute: 0}, value: {:bool, false}}
        ]
      })

      proto = %ProtoHeader{
        initiator: true, needs_ack: true, opcode: 0x06,
        exchange_id: 2, protocol_id: 0x0001, payload: payload
      }

      {[{:reply, reply}, _mrp], _mgr} = ExchangeManager.handle_message(mgr, proto, 100)

      assert reply.opcode == 0x07  # write_response
      assert {:ok, %IM.WriteResponse{}} = IM.decode(:write_response, reply.payload)
    end

    test "InvokeRequest → InvokeResponse" do
      mgr = new_manager()

      payload = IM.encode(%IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: 1, cluster: 6, command: 1}, fields: nil}
        ]
      })

      proto = %ProtoHeader{
        initiator: true, needs_ack: true, opcode: 0x08,
        exchange_id: 3, protocol_id: 0x0001, payload: payload
      }

      {[{:reply, reply}, _mrp], _mgr} = ExchangeManager.handle_message(mgr, proto, 100)

      assert reply.opcode == 0x09  # invoke_response
      assert {:ok, %IM.InvokeResponse{}} = IM.decode(:invoke_response, reply.payload)
    end

    test "unknown protocol returns error" do
      mgr = new_manager()

      proto = %ProtoHeader{
        initiator: true, needs_ack: false, opcode: 0x01,
        exchange_id: 1, protocol_id: 0xFFFF, payload: <<>>
      }

      {actions, _mgr} = ExchangeManager.handle_message(mgr, proto, 100)
      assert [{:error, :unsupported_protocol}] = actions
    end

    test "response opcode with no handler match produces ACK" do
      mgr = new_manager()

      # report_data (0x05) is a response, not a request — no response_opcode mapping
      payload = IM.encode(%IM.ReportData{attribute_reports: []})

      proto = %ProtoHeader{
        initiator: true, needs_ack: true, opcode: 0x05,
        exchange_id: 1, protocol_id: 0x0001, payload: payload
      }

      {actions, _mgr} = ExchangeManager.handle_message(mgr, proto, 100)

      # No content reply, just ACK
      assert [{:ack, 100}] = actions
    end
  end

  # ── Timed exchanges ──────────────────────────────────────────────

  describe "timed exchanges" do
    defp timed_request_proto(exchange_id, timeout_ms \\ 5000) do
      payload = IM.encode(%IM.TimedRequest{timeout_ms: timeout_ms})

      %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: 0x0A,
        exchange_id: exchange_id,
        protocol_id: 0x0001,
        payload: payload
      }
    end

    test "TimedRequest returns StatusResponse and keeps exchange open" do
      mgr = new_manager()
      proto = timed_request_proto(10)

      {actions, mgr} = ExchangeManager.handle_message(mgr, proto, 100)

      # Should reply with StatusResponse
      assert [{:reply, reply}, {:schedule_mrp, 10, 0, _timeout}] = actions
      assert reply.opcode == 0x01  # status_response
      assert {:ok, %IM.StatusResponse{status: 0}} = IM.decode(:status_response, reply.payload)

      # Exchange should still be open (timed)
      assert Map.has_key?(mgr.exchanges, 10)
      assert Map.has_key?(mgr.timed_exchanges, 10)
    end

    test "timed exchange records deadline" do
      mgr = new_manager()
      proto = timed_request_proto(10, 10_000)

      before = System.monotonic_time(:millisecond)
      {_actions, mgr} = ExchangeManager.handle_message(mgr, proto, 100)
      after_time = System.monotonic_time(:millisecond)

      deadline = mgr.timed_exchanges[10]
      assert deadline >= before + 10_000
      assert deadline <= after_time + 10_000
    end

    test "subsequent write on same exchange succeeds" do
      mgr = new_manager()

      # 1. Send TimedRequest
      timed_proto = timed_request_proto(10, 30_000)
      {_actions, mgr} = ExchangeManager.handle_message(mgr, timed_proto, 100)

      # 2. Send WriteRequest on same exchange
      write_payload = IM.encode(%IM.WriteRequest{
        write_requests: [
          %{version: 0, path: %{endpoint: 1, cluster: 6, attribute: 0}, value: {:bool, true}}
        ],
        timed_request: true
      })

      write_proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: 0x06,
        exchange_id: 10,
        protocol_id: 0x0001,
        payload: write_payload
      }

      {actions, mgr} = ExchangeManager.handle_message(mgr, write_proto, 101)

      # Should get WriteResponse
      assert [{:reply, reply}, {:schedule_mrp, 10, 0, _timeout}] = actions
      assert reply.opcode == 0x07  # write_response

      # Exchange and timed state should be cleaned up
      assert mgr.exchanges == %{}
      assert mgr.timed_exchanges == %{}
    end

    test "subsequent invoke on same exchange succeeds" do
      mgr = new_manager()

      # 1. Send TimedRequest
      timed_proto = timed_request_proto(10, 30_000)
      {_actions, mgr} = ExchangeManager.handle_message(mgr, timed_proto, 100)

      # 2. Send InvokeRequest on same exchange
      invoke_payload = IM.encode(%IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: 1, cluster: 6, command: 1}, fields: nil}
        ],
        timed_request: true
      })

      invoke_proto = %ProtoHeader{
        initiator: true,
        needs_ack: true,
        opcode: 0x08,
        exchange_id: 10,
        protocol_id: 0x0001,
        payload: invoke_payload
      }

      {actions, mgr} = ExchangeManager.handle_message(mgr, invoke_proto, 101)

      assert [{:reply, reply}, {:schedule_mrp, 10, 0, _timeout}] = actions
      assert reply.opcode == 0x09  # invoke_response

      assert mgr.timed_exchanges == %{}
    end
  end

  # ── Initiator side ─────────────────────────────────────────────

  describe "initiator" do
    test "initiate assigns exchange_id and builds ProtoHeader" do
      mgr = new_manager()

      payload = IM.encode(%IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 6, attribute: 0}]
      })

      {proto, _actions, mgr} =
        ExchangeManager.initiate(mgr, 0x0001, :read_request, payload)

      assert proto.exchange_id == 1
      assert proto.initiator == true
      assert proto.needs_ack == true
      assert proto.opcode == 0x02  # read_request
      assert proto.protocol_id == 0x0001

      # Next exchange gets ID 2
      {proto2, _actions, _mgr} =
        ExchangeManager.initiate(mgr, 0x0001, :read_request, payload)

      assert proto2.exchange_id == 2
    end

    test "initiate records in MRP and returns schedule action" do
      mgr = new_manager()

      payload = IM.encode(%IM.ReadRequest{attribute_paths: []})

      {_proto, actions, mgr} =
        ExchangeManager.initiate(mgr, 0x0001, :read_request, payload)

      assert [{:schedule_mrp, 1, 0, timeout}] = actions
      assert timeout > 0
      assert MRP.pending?(mgr.mrp, 1)
    end

    test "initiate with reliable: false skips MRP" do
      mgr = new_manager()

      payload = IM.encode(%IM.ReadRequest{attribute_paths: []})

      {proto, actions, mgr} =
        ExchangeManager.initiate(mgr, 0x0001, :read_request, payload, reliable: false)

      assert actions == []
      refute MRP.pending?(mgr.mrp, proto.exchange_id)
      assert proto.needs_ack == false
    end

    test "initiate registers exchange as :initiator" do
      mgr = new_manager()

      payload = IM.encode(%IM.ReadRequest{attribute_paths: []})

      {_proto, _actions, mgr} =
        ExchangeManager.initiate(mgr, 0x0001, :read_request, payload)

      assert mgr.exchanges[1].role == :initiator
      assert mgr.exchanges[1].protocol == :interaction_model
    end
  end
end
