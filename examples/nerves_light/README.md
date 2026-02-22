# NervesLight

A Matter-enabled smart light running on Raspberry Pi with [Nerves](https://nerves-project.org/) and [MatterEx](https://github.com/TomHoenderdos/matter_ex).

Supports commissioning via IP (Wi-Fi/Ethernet) using chip-tool. BLE commissioning support is included but requires BlueHeron hardware compatibility — see Limitations below.

**Note:** This example uses test vendor/product IDs (0xFFF1/0x8000) which are only accepted by chip-tool and development controllers. Production ecosystems (Apple Home, Google Home) require certified vendor IDs.

## Hardware Requirements

- Raspberry Pi 3 or 4
- MicroSD card (8GB+)
- Wi-Fi network or Ethernet connection

## Setup

### 1. Install Dependencies

Ensure you have Nerves installed: https://hexdocs.pm/nerves/installation.html

```bash
cd examples/nerves_light
export MIX_TARGET=rpi4  # or rpi3
mix deps.get
```

### 2. Configure Wi-Fi

Uncomment and edit the Wi-Fi block in `config/target.exs`:

```elixir
config :vintage_net,
  regulatory_domain: "US",
  config: [
    {"wlan0",
     %{
       type: VintageNetWiFi,
       vintage_net_wifi: %{
         networks: [%{key_mgmt: :wpa_psk, ssid: "YOUR_SSID", psk: "YOUR_PASSWORD"}]
       },
       ipv4: %{method: :dhcp}
     }}
  ]
```

### 3. Add SSH Key

Uncomment the SSH key line in `config/target.exs` so you can access the device:

```elixir
config :nerves_ssh,
  authorized_keys: [
    File.read!(Path.join(System.user_home!(), ".ssh/id_rsa.pub"))
  ]
```

### 4. Build and Burn

```bash
mix firmware
mix burn  # Insert MicroSD card
```

### 5. Connect

After the Pi boots, SSH in:

```bash
ssh nerves.local
```

## Commissioning

### QR Code

On the Nerves IEx prompt:

```elixir
NervesLight.qr_code()
```

This prints a QR code to the terminal. Scan it with chip-tool or a development controller app.

### Manual Pairing Code

```elixir
NervesLight.manual_code()
#=> "34970112332"
```

### chip-tool

```bash
# Commission over IP
chip-tool pairing onnetwork 1 20202021

# Control the light
chip-tool onoff toggle 1 1
chip-tool onoff on 1 1
chip-tool onoff off 1 1
```

## IEx Commands

```elixir
NervesLight.on()       # Turn light on
NervesLight.off()      # Turn light off
NervesLight.toggle()   # Toggle light
NervesLight.on?()      # Check state
```

## Configuration

Default commissioning parameters in `config/config.exs`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `discriminator` | 3840 | 12-bit commissioning discriminator |
| `passcode` | 20202021 | Setup passcode |
| `vendor_id` | 0xFFF1 | Test vendor ID |
| `product_id` | 0x8000 | Test product ID |

## Development

Run on host (without hardware):

```bash
export MIX_TARGET=host
mix deps.get
iex -S mix
```

## Limitations

- **Test IDs only**: Uses test vendor/product IDs — not accepted by production Matter ecosystems
- **BLE commissioning**: Included but depends on BlueHeron hardware compatibility with your RPi's Bluetooth controller. IP commissioning is the primary tested path.
- **PBKDF2 salt**: Regenerated on every boot. For production use, persist the salt to the filesystem.
- **No GPIO control**: The OnOff cluster controls in-memory state only. Wire up `Circuits.GPIO` for physical LED control.
