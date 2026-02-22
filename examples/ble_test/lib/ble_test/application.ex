defmodule BleTest.Application do
  @moduledoc false

  use Application
  require Logger

  @target Mix.target()

  @impl true
  def start(_type, _args) do
    children =
      [
        # Children for all targets
      ] ++ target_children()

    opts = [strategy: :one_for_one, name: BleTest.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # BlueHeron starts via its own application supervisor (config-driven).
        # We just need to register our GATT services and start advertising
        # after a short delay to let the HCI transport initialize.
        if @target != :host do
          spawn(fn -> setup_ble() end)
        end

        {:ok, pid}

      error ->
        error
    end
  end

  if Mix.target() == :host do
    defp target_children, do: []
  else
    defp target_children, do: []
  end

  defp setup_ble do
    # Give BlueHeron time to initialize the HCI transport and load firmware
    Process.sleep(3_000)
    Logger.info("[BleTest] Setting up BLE services...")

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
          {:gap, :device_name} -> "BleTest"
          {:gap, :appearance} -> <<0x00, 0x00>>
        end
      })

    # Register a simple test service with a read characteristic
    # Using a random 128-bit UUID for the test service
    test_service =
      BlueHeron.GATT.Service.new(%{
        id: :test,
        type: 0xFFE0,
        characteristics: [
          BlueHeron.GATT.Characteristic.new(%{
            id: {:test, :value},
            type: 0xFFE1,
            properties: 0x02
          })
        ],
        read: fn
          {:test, :value} -> "Hello from BleTest!"
        end
      })

    BlueHeron.Peripheral.add_service(gap_service)
    Logger.info("[BleTest] GAP service registered")

    BlueHeron.Peripheral.add_service(test_service)
    Logger.info("[BleTest] Test service registered (0xFFE0)")

    # Build advertising data: flags + complete local name
    ad_data = build_advertising_data("BleTest")

    case BlueHeron.Broadcaster.set_advertising_data(ad_data) do
      :ok ->
        Logger.info("[BleTest] Advertising data set")

        case BlueHeron.Broadcaster.start_advertising() do
          :ok ->
            Logger.info("[BleTest] BLE advertising started! Device should be visible as 'BleTest'")

          {:error, reason} ->
            Logger.error("[BleTest] Failed to start advertising: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("[BleTest] Failed to set advertising data: #{inspect(reason)}")
    end
  end

  defp build_advertising_data(name) do
    # AD type 0x01: Flags (LE General Discoverable + BR/EDR Not Supported)
    flags = <<0x02, 0x01, 0x06>>

    # AD type 0x09: Complete Local Name
    name_bytes = name
    name_ad = <<byte_size(name_bytes) + 1, 0x09, name_bytes::binary>>

    flags <> name_ad
  end
end
