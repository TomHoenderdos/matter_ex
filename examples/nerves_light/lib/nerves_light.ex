defmodule NervesLight do
  @moduledoc """
  A Matter-enabled smart light running on Nerves.

  ## Quick start

      # Print the QR code for commissioning
      NervesLight.qr_code()

      # Get the manual pairing code
      NervesLight.manual_code()

      # Toggle the light
      NervesLight.toggle()

      # Turn on/off
      NervesLight.on()
      NervesLight.off()
  """

  @doc "Print the commissioning QR code to the console."
  def qr_code do
    config = Application.get_all_env(:nerves_light)

    payload =
      MatterEx.SetupPayload.qr_code_payload(
        vendor_id: config[:vendor_id],
        product_id: config[:product_id],
        discriminator: config[:discriminator],
        passcode: config[:passcode]
      )

    payload
    |> EQRCode.encode()
    |> EQRCode.render()

    IO.puts("\nSetup code: #{payload}")
    :ok
  end

  @doc "Return the 11-digit manual pairing code."
  def manual_code do
    config = Application.get_all_env(:nerves_light)

    MatterEx.SetupPayload.manual_pairing_code(
      discriminator: config[:discriminator],
      passcode: config[:passcode]
    )
  end

  @doc "Toggle the light on/off."
  def toggle do
    NervesLight.Device.invoke_command(1, :on_off, :toggle)
  end

  @doc "Turn the light on."
  def on do
    NervesLight.Device.invoke_command(1, :on_off, :on)
  end

  @doc "Turn the light off."
  def off do
    NervesLight.Device.invoke_command(1, :on_off, :off)
  end

  @doc "Check if the light is on."
  def on? do
    NervesLight.Device.read_attribute(1, :on_off, :on_off)
  end

  @doc false
  def hello do
    IO.puts("""

    NervesLight - Matter Smart Light
    ================================
    Commands:
      NervesLight.qr_code()    - Show QR code
      NervesLight.manual_code() - Show manual pairing code
      NervesLight.toggle()      - Toggle light
      NervesLight.on()          - Turn on
      NervesLight.off()         - Turn off
    """)
  end
end
