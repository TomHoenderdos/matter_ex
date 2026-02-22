defmodule NervesLight.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_all_env(:nerves_light)
    discriminator = config[:discriminator] || 3840
    passcode = config[:passcode] || 20202021
    vendor_id = config[:vendor_id] || 0xFFF1
    product_id = config[:product_id] || 0x8000

    children =
      [
        # Matter device (cluster supervisors)
        NervesLight.Device,

        # mDNS responder for IP-based discovery
        {MatterEx.MDNS, name: MatterEx.MDNS},

        # Matter protocol stack (UDP + TCP + BLE)
        {MatterEx.Node,
         name: MatterEx.Node,
         device: NervesLight.Device,
         passcode: passcode,
         # TODO: persist salt to filesystem for stable PASE verifier across reboots
         salt: :crypto.strong_rand_bytes(32),
         iterations: 1000,
         port: 5540}
      ] ++ ble_children(discriminator, vendor_id, product_id)

    opts = [strategy: :one_for_one, name: NervesLight.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Advertise commissioning service via mDNS
    port = MatterEx.Node.port(MatterEx.Node)

    service =
      MatterEx.MDNS.commissioning_service(
        port: port,
        discriminator: discriminator,
        vendor_id: vendor_id,
        product_id: product_id,
        device_name: "NervesLight"
      )

    MatterEx.MDNS.advertise(MatterEx.MDNS, service)

    # Print commissioning info after boot
    print_commissioning_info()

    result
  end

  # Only start BLE transport on target hardware (not on host)
  defp ble_children(discriminator, vendor_id, product_id) do
    if Code.ensure_loaded?(BlueHeron) do
      [
        {MatterEx.Transport.BLE,
         owner: MatterEx.Node,
         discriminator: discriminator,
         vendor_id: vendor_id,
         product_id: product_id,
         adapter: NervesLight.BLEAdapter}
      ]
    else
      []
    end
  end

  defp print_commissioning_info do
    config = Application.get_all_env(:nerves_light)

    qr_payload =
      MatterEx.SetupPayload.qr_code_payload(
        vendor_id: config[:vendor_id],
        product_id: config[:product_id],
        discriminator: config[:discriminator],
        passcode: config[:passcode]
      )

    manual_code =
      MatterEx.SetupPayload.manual_pairing_code(
        discriminator: config[:discriminator],
        passcode: config[:passcode]
      )

    IO.puts("""

    ========================================
     NervesLight - Matter Smart Light
    ========================================
     QR Code Payload: #{qr_payload}
     Manual Code:     #{manual_code}
    ========================================
     Run NervesLight.qr_code() to display
     the QR code in the terminal.
    ========================================
    """)
  end
end
