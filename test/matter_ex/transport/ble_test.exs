defmodule MatterEx.Transport.BLETest do
  use ExUnit.Case, async: false

  alias MatterEx.Transport.BLE
  alias MatterEx.Transport.BLE.MockAdapter
  alias MatterEx.Transport.BTP

  @default_opts [
    discriminator: 3840,
    vendor_id: 0xFFF1,
    product_id: 0x8001,
    adapter: MockAdapter
  ]

  defp start_ble(extra_opts \\ []) do
    opts = Keyword.merge(@default_opts, [owner: self()] ++ extra_opts)
    {:ok, pid} = BLE.start_link(opts)
    # Get the adapter handle from GenServer state for mock inspection
    adapter_handle = :sys.get_state(pid).adapter_handle
    {pid, adapter_handle}
  end

  defp handshake_request(opts \\ []) do
    BTP.handshake_request(opts)
  end

  # ── GATT Constants ─────────────────────────────────────────────────

  describe "GATT constants" do
    test "service UUID" do
      assert BLE.gatt_service_uuid() == 0xFFF6
    end

    test "TX characteristic UUID" do
      assert BLE.tx_characteristic_uuid() == "18EE2EF5-263D-4559-959F-4F9C429F9D11"
    end

    test "RX characteristic UUID" do
      assert BLE.rx_characteristic_uuid() == "18EE2EF5-263D-4559-959F-4F9C429F9D12"
    end

    test "additional data UUID" do
      assert BLE.additional_data_uuid() == "64630238-8772-45F2-B87D-748A83218F04"
    end
  end

  # ── Lifecycle ──────────────────────────────────────────────────────

  describe "lifecycle" do
    test "start_link succeeds with mock adapter" do
      {pid, _handle} = start_ble()
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "adapter receives correct start opts" do
      {pid, handle} = start_ble()
      opts = MockAdapter.start_opts(handle)
      assert opts[:discriminator] == 3840
      assert opts[:vendor_id] == 0xFFF1
      assert opts[:product_id] == 0x8001
      GenServer.stop(pid)
    end

    test "starts advertising on init" do
      {pid, handle} = start_ble()
      assert MockAdapter.advertising?(handle) == true
      GenServer.stop(pid)
    end

    test "stop_advertising delegates to adapter" do
      {pid, handle} = start_ble()
      BLE.stop_advertising(pid)
      assert MockAdapter.advertising?(handle) == false
      GenServer.stop(pid)
    end

    test "terminate calls adapter.stop" do
      {pid, handle} = start_ble()
      GenServer.stop(pid)
      # Give Agent time to process
      Process.sleep(10)
      assert MockAdapter.stopped?(handle) == true
    end
  end

  # ── Connection Events ──────────────────────────────────────────────

  describe "connection" do
    test "owner receives :ble_connected" do
      {pid, handle} = start_ble()
      MockAdapter.simulate_connect(handle)
      assert_receive {:ble_connected, ^pid}, 100
      GenServer.stop(pid)
    end

    test "phase transitions to handshaking on connect" do
      {pid, handle} = start_ble()
      MockAdapter.simulate_connect(handle)
      assert_receive {:ble_connected, _}, 100

      state = :sys.get_state(pid)
      assert state.phase == :handshaking
      GenServer.stop(pid)
    end
  end

  # ── Handshake ──────────────────────────────────────────────────────

  describe "handshake" do
    test "device sends handshake response after receiving request" do
      {pid, handle} = start_ble()
      MockAdapter.simulate_connect(handle)
      assert_receive {:ble_connected, _}, 100

      MockAdapter.simulate_data(handle, handshake_request())
      Process.sleep(20)

      packets = MockAdapter.sent_packets(handle)
      assert length(packets) == 1

      {:response, params} = BTP.decode_handshake(hd(packets))
      assert params.selected_version == 4
      GenServer.stop(pid)
    end

    test "phase transitions to connected after handshake" do
      {pid, handle} = start_ble()
      MockAdapter.simulate_connect(handle)
      assert_receive {:ble_connected, _}, 100

      MockAdapter.simulate_data(handle, handshake_request())
      Process.sleep(20)

      state = :sys.get_state(pid)
      assert state.phase == :connected
      GenServer.stop(pid)
    end

    test "MTU negotiated to minimum of both sides" do
      {pid, handle} = start_ble()
      MockAdapter.simulate_connect(handle)
      assert_receive {:ble_connected, _}, 100

      MockAdapter.simulate_data(handle, handshake_request(mtu: 128))
      Process.sleep(20)

      state = :sys.get_state(pid)
      # Device default is 247, commissioner proposes 128, should pick 128
      assert state.btp.mtu == 128
      GenServer.stop(pid)
    end
  end

  # ── Data Flow ──────────────────────────────────────────────────────

  describe "data flow" do
    setup do
      {pid, handle} = start_ble()
      MockAdapter.simulate_connect(handle)
      assert_receive {:ble_connected, _}, 100
      MockAdapter.simulate_data(handle, handshake_request())
      Process.sleep(20)
      %{pid: pid, handle: handle}
    end

    test "single-fragment message delivered to owner", %{pid: pid, handle: handle} do
      # Simulate incoming BTP data (a single-fragment message)
      tx_state = BTP.new()
      {[packet], _} = BTP.fragment(tx_state, "hello matter")
      MockAdapter.simulate_data(handle, packet)

      assert_receive {:ble_data, ^pid, "hello matter"}, 100
      GenServer.stop(pid)
    end

    test "multi-fragment message delivered after last fragment", %{pid: pid, handle: handle} do
      message = :binary.copy("x", 300)
      tx_state = BTP.new(mtu: 64)
      {packets, _} = BTP.fragment(tx_state, message)

      # Send all but last
      for packet <- Enum.slice(packets, 0..-2//1) do
        MockAdapter.simulate_data(handle, packet)
        Process.sleep(5)
      end

      # Should not have received the message yet
      refute_received {:ble_data, _, _}

      # Send last fragment
      MockAdapter.simulate_data(handle, List.last(packets))
      assert_receive {:ble_data, ^pid, ^message}, 100
      GenServer.stop(pid)
    end

    test "send/2 fragments and sends via adapter", %{pid: pid, handle: handle} do
      # Clear the handshake response from sent_packets
      _initial_packets = MockAdapter.sent_packets(handle)

      :ok = BLE.send(pid, "response data")
      Process.sleep(20)

      # Should have sent handshake response + the data packet(s)
      packets = MockAdapter.sent_packets(handle)
      # First packet is handshake response, rest are data
      data_packets = tl(packets)
      assert length(data_packets) >= 1

      # Reassemble to verify
      rx = BTP.new()

      {result, _} =
        Enum.reduce(data_packets, {nil, rx}, fn pkt, {_r, state} ->
          case BTP.receive_segment(state, pkt) do
            {:ok, s} -> {nil, s}
            {:complete, msg, s} -> {msg, s}
          end
        end)

      assert result == "response data"
      GenServer.stop(pid)
    end

    test "send/2 returns error when not connected" do
      {pid, _handle} = start_ble()
      assert {:error, :not_connected} = BLE.send(pid, "data")
      GenServer.stop(pid)
    end
  end

  # ── Disconnection ──────────────────────────────────────────────────

  describe "disconnection" do
    test "owner receives :ble_disconnected" do
      {pid, handle} = start_ble()
      MockAdapter.simulate_connect(handle)
      assert_receive {:ble_connected, _}, 100

      MockAdapter.simulate_disconnect(handle)
      assert_receive {:ble_disconnected, ^pid}, 100
      GenServer.stop(pid)
    end

    test "phase resets to idle after disconnect" do
      {pid, handle} = start_ble()
      MockAdapter.simulate_connect(handle)
      assert_receive {:ble_connected, _}, 100
      MockAdapter.simulate_data(handle, handshake_request())
      Process.sleep(20)

      MockAdapter.simulate_disconnect(handle)
      assert_receive {:ble_disconnected, _}, 100

      state = :sys.get_state(pid)
      assert state.phase == :idle
      GenServer.stop(pid)
    end

    test "BTP state resets after disconnect" do
      {pid, handle} = start_ble()
      MockAdapter.simulate_connect(handle)
      assert_receive {:ble_connected, _}, 100
      MockAdapter.simulate_data(handle, handshake_request())
      Process.sleep(20)

      MockAdapter.simulate_disconnect(handle)
      assert_receive {:ble_disconnected, _}, 100

      state = :sys.get_state(pid)
      assert state.btp.tx_seq == 0
      assert state.btp.rx_seq == nil
      assert state.btp.rx_buffer == []
      GenServer.stop(pid)
    end

    test "reconnection after disconnect works" do
      {pid, handle} = start_ble()

      # First connection
      MockAdapter.simulate_connect(handle)
      assert_receive {:ble_connected, _}, 100
      MockAdapter.simulate_data(handle, handshake_request())
      Process.sleep(20)
      MockAdapter.simulate_disconnect(handle)
      assert_receive {:ble_disconnected, _}, 100

      # Second connection
      MockAdapter.simulate_connect(handle)
      assert_receive {:ble_connected, ^pid}, 100
      MockAdapter.simulate_data(handle, handshake_request())
      Process.sleep(20)

      state = :sys.get_state(pid)
      assert state.phase == :connected

      # Data should flow on second connection
      tx = BTP.new()
      {[pkt], _} = BTP.fragment(tx, "reconnected")
      MockAdapter.simulate_data(handle, pkt)
      assert_receive {:ble_data, ^pid, "reconnected"}, 100

      GenServer.stop(pid)
    end
  end
end
