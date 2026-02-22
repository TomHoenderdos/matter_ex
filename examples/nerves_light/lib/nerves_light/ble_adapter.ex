defmodule NervesLight.BLEAdapter do
  @moduledoc """
  BLE adapter for MatterEx using BlueHeron ~> 0.5.

  Implements `MatterEx.Transport.BLE.Adapter` to provide BLE commissioning
  on Raspberry Pi hardware via the onboard Bluetooth controller.

  ## Configuration

  Configure the UART transport in your `config/target.exs`:

      config :blue_heron,
        transport: [
          device: "/dev/ttyS0",
          speed: 115_200
        ]

  ## Limitations

  Matter spec requires indications on the TX characteristic, but BlueHeron 0.5
  only supports notifications via `Peripheral.notify/3`. Most Matter controllers
  accept notifications as well.
  """

  @behaviour MatterEx.Transport.BLE.Adapter

  require Logger

  # Matter BLE characteristic UUIDs (128-bit as integers)
  @rx_char_uuid 0x18EE2EF5263D4559959F4F9C429F9D12
  @tx_char_uuid 0x18EE2EF5263D4559959F4F9C429F9D11

  @impl true
  def start(opts) do
    owner = Keyword.fetch!(opts, :owner)

    # Register GAP service (required for BLE peripherals)
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

    # Register Matter BLE service with RX (write) and TX (notify) characteristics
    matter_service =
      BlueHeron.GATT.Service.new(%{
        id: :matter,
        type: 0xFFF6,
        characteristics: [
          BlueHeron.GATT.Characteristic.new(%{
            id: {:matter, :rx},
            type: @rx_char_uuid,
            # Write only (0x08) — BlueHeron's GATT server doesn't handle
            # Write Without Response (ATT WriteCommand), so we only advertise Write
            properties: 0x08
          }),
          BlueHeron.GATT.Characteristic.new(%{
            id: {:matter, :tx},
            type: @tx_char_uuid,
            # Notify — spec wants Indicate but BlueHeron only supports notify
            properties: 0x10,
            # CCCD descriptor is required so clients can enable notifications
            # by writing <<0x01, 0x00>> — this triggers the subscribe callback
            descriptor: BlueHeron.GATT.Characteristic.Descriptor.new(%{permissions: 0})
          })
        ],
        write: fn
          {:matter, :rx}, data ->
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

    BlueHeron.Peripheral.add_service(gap_service)
    BlueHeron.Peripheral.add_service(matter_service)

    {:ok, %{owner: owner, opts: opts}}
  end

  @impl true
  def start_advertising(handle, _ad_data) do
    discriminator = Keyword.get(handle.opts, :discriminator, 0)
    vendor_id = Keyword.get(handle.opts, :vendor_id, 0)
    product_id = Keyword.get(handle.opts, :product_id, 0)

    ad_data = build_advertising_data(discriminator, vendor_id, product_id)

    with :ok <- BlueHeron.Broadcaster.set_advertising_data(ad_data),
         :ok <- BlueHeron.Broadcaster.start_advertising() do
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

  # Build raw BLE advertising data bytes for Matter commissioning.
  # AD format: <<length, type, data...>> repeated.
  defp build_advertising_data(discriminator, vendor_id, product_id) do
    # AD Flags: LE General Discoverable (0x02) + BR/EDR Not Supported (0x04)
    flags = <<0x02, 0x01, 0x06>>

    # Incomplete List of 16-bit Service UUIDs: Matter (0xFFF6)
    service_uuids = <<0x03, 0x02, 0xF6, 0xFF>>

    # Service Data (type 0x16): Matter service UUID + commissioning payload
    # Matter BLE advertisement payload per spec 5.4.2.5.1
    service_data_payload =
      <<
        0x00,
        discriminator::little-16,
        vendor_id::little-16,
        product_id::little-16
      >>

    service_data =
      <<byte_size(service_data_payload) + 3, 0x16, 0xF6, 0xFF>> <> service_data_payload

    flags <> service_uuids <> service_data
  end
end
