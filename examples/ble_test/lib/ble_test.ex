defmodule BleTest do
  @moduledoc """
  Minimal BLE test for BlueHeron on Pi Zero 2W.

  Tests whether BlueHeron's rpi-zero-2w-bluetooth-support branch
  can initialize the Broadcom BT chip, advertise, and accept connections.
  """

  require Logger

  @doc """
  Print BLE state info.
  """
  def status do
    if Code.ensure_loaded?(BlueHeron) do
      IO.puts("BlueHeron loaded: yes")

      services = PropertyTable.get(BlueHeron.GATT, ["profile"], [])

      IO.puts("GATT services registered: #{length(services)}")

      for service <- services do
        IO.puts("  - #{inspect(service.id)} (type: 0x#{Integer.to_string(service.type, 16)})")
      end
    else
      IO.puts("BlueHeron not loaded (running on host?)")
    end
  end

  @doc """
  Start BLE advertising.
  """
  def start_advertising do
    ad_data = <<0x02, 0x01, 0x06, 0x08, 0x09, "BleTest">>

    with :ok <- BlueHeron.Broadcaster.set_advertising_data(ad_data),
         :ok <- BlueHeron.Broadcaster.start_advertising() do
      Logger.info("[BleTest] Advertising started")
      :ok
    else
      {:error, reason} ->
        Logger.error("[BleTest] Failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stop BLE advertising.
  """
  def stop_advertising do
    case BlueHeron.Broadcaster.stop_advertising() do
      :ok ->
        Logger.info("[BleTest] Advertising stopped")
        :ok

      {:error, reason} ->
        Logger.error("[BleTest] Failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Print usage help.
  """
  def hello do
    IO.puts("""

    BleTest - BlueHeron BLE Test for Pi Zero 2W
    ============================================

    Commands:
      BleTest.status()            - Show BLE state and registered services
      BleTest.start_advertising() - Start BLE advertising
      BleTest.stop_advertising()  - Stop BLE advertising

    Logs:
      RingLogger.next()           - Show recent log messages
      RingLogger.attach()         - Stream logs to console

    The device should auto-advertise on boot as "BleTest".
    Scan for it with: bluetoothctl scan on  (or nRF Connect on phone)
    """)
  end
end
