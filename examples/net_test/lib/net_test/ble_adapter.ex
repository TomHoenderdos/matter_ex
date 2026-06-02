defmodule NetTest.BLEAdapter do
  @behaviour MatterEx.Transport.BLE.Adapter

  import Bitwise

  require Logger

  @rx_char_uuid 0x18EE2EF5263D4559959F4F9C429F9D11
  @tx_char_uuid 0x18EE2EF5263D4559959F4F9C429F9D12

  @impl true
  def start(opts) do
    owner = Keyword.fetch!(opts, :owner)

    gap_service =
      BlueHeron.GATT.Service.new(%{
        id: :gap,
        type: 0x1800,
        characteristics: [
          BlueHeron.GATT.Characteristic.new(%{
            id: {:gap, :device_name},
            type: 0x2A00,
            properties: 0x02
          }),
          BlueHeron.GATT.Characteristic.new(%{
            id: {:gap, :appearance},
            type: 0x2A01,
            properties: 0x02
          })
        ],
        read: fn
          {:gap, :device_name} -> "MatterEx Light"
          {:gap, :appearance} -> <<0x0080::little-16>>
        end
      })

    matter_service =
      BlueHeron.GATT.Service.new(%{
        id: :matter,
        type: 0xFFF6,
        characteristics: [
          # C1 (RX): client → server via Write (must be first per Matter BTP spec)
          # Properties: Write (0x08) required, Write Without Response (0x04) optional
          BlueHeron.GATT.Characteristic.new(%{
            id: {:matter, :rx},
            type: @rx_char_uuid,
            properties: 0x0A
          }),
          # C2 (TX): server → client via indications/notifications
          # Properties: Indicate (0x20) is REQUIRED by Matter BTP spec 4.18.2
          # Notify (0x10) is optional but preferred (no per-PDU ACK overhead)
          BlueHeron.GATT.Characteristic.new(%{
            id: {:matter, :tx},
            type: @tx_char_uuid,
            properties: 0x3E,
            descriptor: BlueHeron.GATT.Characteristic.Descriptor.new(%{permissions: 0})
          })
        ],
        read: fn
          {:matter, :rx} -> <<>>
          {:matter, :tx} -> <<>>
        end,
        write: fn
          {:matter, :rx}, data ->
            send(owner, {:ble_data, :matter_ble, data})
            :ok

          {:matter, :tx}, data ->
            send(owner, {:ble_data, :matter_ble, data})
            :ok
        end,
        subscribe: fn
          {:matter, :tx} ->
            Logger.info("Matter BLE client subscribed to TX")
            send(owner, {:ble_connected, :matter_ble})
        end,
        unsubscribe: fn
          {:matter, :tx} ->
            Logger.info("Matter BLE client unsubscribed from TX")
            send(owner, {:ble_disconnected, :matter_ble})
        end
      })

    # BlueHeron prepends services, so the LAST added gets the LOWEST handles.
    # GAP (0x1800) must have the lowest handles per BLE spec.
    BlueHeron.Peripheral.add_service(matter_service)
    BlueHeron.Peripheral.add_service(gap_service)

    {:ok, %{owner: owner, opts: opts}}
  end

  @impl true
  def start_advertising(handle, _ad_data) do
    discriminator = Keyword.get(handle.opts, :discriminator, 0)
    vendor_id = Keyword.get(handle.opts, :vendor_id, 0)
    product_id = Keyword.get(handle.opts, :product_id, 0)

    # Wait for BlueHeron HCI setup to complete before advertising.
    # BlueHeron starts as an OTP dependency app and runs HCI setup
    # asynchronously — it may not be ready when this is called.
    :ok = wait_for_hci_ready()

    # Log HCI buffer sizes for debugging ACL packet length limits
    try do
      with {:ok, acl_len} <- BlueHeron.HCI.Transport.get_setup_param(:acl_data_packet_length),
           {:ok, le_acl_len} <-
             BlueHeron.HCI.Transport.get_setup_param(:le_acl_data_packet_length) do
        Logger.info("HCI buffer sizes: ACL=#{acl_len}, LE_ACL=#{le_acl_len}")
      end
    rescue
      _ -> Logger.debug("HCI buffer size query not supported")
    end

    # Use a random static address while iterating on the GATT database. macOS
    # CoreBluetooth aggressively caches GATT by peer address.
    random_address = random_static_address()

    :ok =
      BlueHeron.HCI.Transport.send_hci(
        BlueHeron.HCI.Command.LEController.SetRandomAddress.new(random_address: random_address)
      )
      |> case do
        {:ok, %{return_parameters: %{status: 0}}} -> :ok
        other -> other
      end

    Logger.info("BLE random static address set to 0x#{Integer.to_string(random_address, 16)}")

    # Explicitly set advertising parameters:
    # - ADV_IND (0x00): connectable undirected (required for Matter BLE)
    # - own_address_type 0x01: random static address to avoid stale central GATT cache
    # - 100ms interval (0x00A0): fast enough for phone discovery
    :ok =
      BlueHeron.Broadcaster.set_advertising_parameters(
        advertising_type: 0x00,
        own_address_type: 0x01,
        advertising_interval_min: 0x00A0,
        advertising_interval_max: 0x00A0,
        advertising_channel_map: 0x07,
        advertising_filter_policy: 0x00
      )

    Logger.info("Advertising parameters set (ADV_IND, random static addr, 100ms)")

    ad_data = build_advertising_data(discriminator, vendor_id, product_id)

    # Scan response with device name (sent in response to active scans)
    device_name = "MatterEx Light"
    scan_response = <<byte_size(device_name) + 1, 0x09>> <> device_name

    with :ok <- BlueHeron.Broadcaster.set_advertising_data(ad_data),
         :ok <- BlueHeron.Broadcaster.set_scan_response_data(scan_response),
         :ok <- BlueHeron.Broadcaster.start_advertising() do
      Logger.info("BLE advertising started (Matter FFF6, random static addr)")

      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to start BLE advertising: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def stop_advertising(_handle) do
    BlueHeron.Broadcaster.stop_advertising()
    :ok
  end

  @impl true
  def send_data(_handle, _connection_ref, data) do
    BlueHeron.Peripheral.notify(:matter, {:matter, :tx}, data)
  end

  @impl true
  def stop(_handle) do
    BlueHeron.Broadcaster.stop_advertising()
    BlueHeron.Peripheral.delete_service(:matter)
    BlueHeron.Peripheral.delete_service(:gap)
    :ok
  end

  defp wait_for_hci_ready(timeout_ms \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_hci_ready(deadline)
  end

  defp do_wait_for_hci_ready(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      Logger.error("Timed out waiting for BlueHeron HCI setup")
      {:error, :timeout}
    else
      if BlueHeron.HCI.Transport.setup_complete?() do
        Logger.info("BlueHeron HCI setup complete — ready for advertising")
        :ok
      else
        Process.sleep(100)
        do_wait_for_hci_ready(deadline)
      end
    end
  end

  defp random_static_address do
    :crypto.strong_rand_bytes(6)
    |> :binary.decode_unsigned()
    |> band(0x3FFFFFFFFFFF)
    |> bor(0xC00000000000)
  end

  defp build_advertising_data(discriminator, vendor_id, product_id) do
    flags = <<0x02, 0x01, 0x06>>
    # AD type 0x03 = Complete List of 16-bit Service UUIDs (Matter spec 5.4.2.5.3)
    service_uuids = <<0x03, 0x03, 0xF6, 0xFF>>

    # Matter BLE service data (spec 5.4.2.5.6):
    #   Byte 0:   OpCode (0x00 = commissionable)
    #   Byte 1-2: Discriminator (12-bit long discriminator, LE 16-bit, upper 4 bits reserved)
    #   Byte 3-4: Vendor ID (LE 16-bit)
    #   Byte 5-6: Product ID (LE 16-bit)
    #   Byte 7:   Additional Data Flag (0x00 = none)
    service_data_payload =
      <<
        0x00,
        discriminator::little-16,
        vendor_id::little-16,
        product_id::little-16,
        0x00
      >>

    service_data =
      <<byte_size(service_data_payload) + 3, 0x16, 0xF6, 0xFF>> <> service_data_payload

    flags <> service_uuids <> service_data
  end
end
