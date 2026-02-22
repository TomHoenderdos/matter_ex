import Config

# Use RingLogger on target (no console available)
config :logger, backends: [RingLogger]

# Shoehorn configuration
config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Nerves runtime
config :nerves_runtime, :kernel, use_system_registry: false

# BlueHeron UART transport for RPi onboard Bluetooth
config :blue_heron,
  transport: [
    device: "/dev/ttyS0",
    speed: 115_200
  ]

# Wi-Fi configuration — uncomment and set your credentials
# config :vintage_net,
#   regulatory_domain: "US",
#   config: [
#     {"wlan0",
#      %{
#        type: VintageNetWiFi,
#        vintage_net_wifi: %{
#          networks: [%{key_mgmt: :wpa_psk, ssid: "YOUR_SSID", psk: "YOUR_PASSWORD"}]
#        },
#        ipv4: %{method: :dhcp}
#      }}
#   ]

# Authorized SSH keys — add your public key for remote access
# Without a key here, SSH will be locked out on target hardware.
config :nerves_ssh,
  authorized_keys: [
    # File.read!(Path.join(System.user_home!(), ".ssh/id_rsa.pub"))
  ]
