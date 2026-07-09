defmodule MatterExample.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    if ble_enabled?() do
      # Power on the Broadcom Bluetooth chip via the firmware GPIO expander.
      # Needed on cold boot when BT_REG_ON defaults to low.
      # Firmware download is handled by BlueHeron's BroadcomInit during HCI setup.
      power_on_bluetooth()
    end

    # Pre-compute commissioning service config so we can pass the instance
    # name to the Node (needed for mDNS transition after commissioning)
    service =
      MatterEx.MDNS.commissioning_service(
        port: 5540,
        discriminator: 3840,
        vendor: :test,
        product: :matter_example,
        device_name: "MatterExample"
      )

    children =
      [
        MatterExample.Device,
        MatterExample.FakeSensor,
        {MatterEx.MDNS, [name: MatterEx.MDNS] ++ mdns_interface_opts()},
        {MatterEx.Node,
         name: MatterEx.Node,
         device: MatterExample.Device,
         passcode: 20_202_021,
         salt: :crypto.strong_rand_bytes(32),
         iterations: 1000,
         port: 5540,
         mdns: MatterEx.MDNS,
         # Persist fabric credentials so pairing survives a restart. Swap the
         # adapter for your own MatterEx.Storage backend as needed.
         storage: {MatterEx.Storage.FileSystem, dir: storage_dir()},
         commissioning_service: service,
         commissioning_instance: service[:instance]}
      ] ++ ble_children() ++ target_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MatterExample.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Post-startup: advertise the commissioning service via mDNS, but only when
    # not already commissioned. A restored device advertises operationally (the
    # node does this during restore) and must not re-enter pairing mode.
    unless MatterEx.Commissioning.commissioned?() do
      try do
        MatterEx.MDNS.advertise(MatterEx.MDNS, service)
      catch
        :exit, reason ->
          Logger.warning("MDNS advertise failed: #{inspect(reason)}, continuing without mDNS")
      end
    end

    qr_payload =
      MatterEx.SetupPayload.qr_code_payload(
        vendor: :test,
        product: :matter_example,
        discriminator: 3840,
        passcode: 20_202_021
      )

    manual_code =
      MatterEx.SetupPayload.manual_pairing_code(
        discriminator: 3840,
        passcode: 20_202_021
      )

    Logger.info("""
    ========================================
     MatterExample - Matter Smart Light
    ========================================
     Endpoint 1: dimmable light
     Endpoint 2: fake temperature sensor
     Endpoint 3: fake humidity sensor
     Endpoint 4: fake illuminance sensor
     Endpoint 5: fake occupancy sensor
     Endpoint 6: fake contact sensor
     Endpoint 7: fake air quality sensor
     QR Code Payload: #{qr_payload}
     Manual Code:     #{manual_code}
    ========================================
    """)

    result
  end

  defp ble_children do
    if ble_enabled?() and Code.ensure_loaded?(BlueHeron) do
      [
        {MatterEx.Transport.BLE,
         owner: MatterEx.Node,
         discriminator: 3840,
         vendor: :test,
         product: :matter_example,
         adapter: MatterExample.BLEAdapter}
      ]
    else
      []
    end
  end

  defp ble_enabled?, do: Application.get_env(:matter_example, :ble_enabled, false)

  if Mix.target() == :host do
    defp mdns_interface_opts, do: []
  else
    defp mdns_interface_opts, do: [interface: "wlan0"]
  end

  if Mix.target() == :host do
    defp storage_dir, do: Path.join(System.tmp_dir!(), "matter_example")
  else
    # Nerves: /data is the writable, persistent application partition.
    defp storage_dir, do: "/data/matter_example"
  end

  if Mix.target() == :host do
    defp power_on_bluetooth, do: :ok
  else
    # Power on the Broadcom Bluetooth chip and restart BlueHeron.
    # BlueHeron auto-starts as a dependency app BEFORE this Application, so its
    # initial HCI setup fails (chip not powered). We stop it, power-cycle the chip,
    # then restart it — BlueHeron's BroadcomInit handles firmware download natively.
    defp power_on_bluetooth do
      if Code.ensure_loaded?(Circuits.GPIO) do
        require Logger

        # Stop BlueHeron so it releases the UART during chip power-cycle
        Logger.info("Stopping BlueHeron for BT chip power-on...")
        Application.stop(:blue_heron)
        Process.sleep(100)

        # gpiochip1 is the RPi firmware GPIO expander where BT_REG_ON lives.
        # Try it first; gpiochip0 is the main SoC GPIO (fallback for other boards).
        result =
          Enum.find_value(["gpiochip1", "gpiochip0"], fn chip ->
            case Circuits.GPIO.open({chip, 0}, :output, initial_value: 0) do
              {:ok, gpio} ->
                # Toggle BT_REG_ON: low → wait → high to ensure clean chip reset
                # (on warm reboot the chip may retain state from previous session)
                Logger.info("BT_REG_ON: resetting on #{chip} line 0")
                Process.sleep(50)
                Circuits.GPIO.write(gpio, 1)
                Logger.info("BT_REG_ON: asserted on #{chip} line 0")
                # Keep the GPIO reference alive so it doesn't get GC'd and released
                Process.put(:bt_reg_on_gpio, gpio)
                true

              {:error, _} ->
                nil
            end
          end)

        unless result do
          Logger.warning("BT_REG_ON: could not assert on any gpiochip")
        end

        # Give the chip time to power on and initialize
        Process.sleep(250)

        # Restart BlueHeron — it will now detect BCM4345C5 and download
        # patchram firmware automatically via BroadcomInit
        Logger.info("Restarting BlueHeron (will auto-download firmware)...")
        Application.ensure_all_started(:blue_heron)
      end
    end
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end
  else
    defp target_children() do
      [
        # Children for all targets except host
        # Starts a worker by calling: Target.Worker.start_link(arg)
        # {Target.Worker, arg},
      ]
    end
  end
end
