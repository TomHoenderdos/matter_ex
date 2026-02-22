import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without real-time clocks.
config :nerves, :erlinit, update_clock: true

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://hexdocs.pm/nerves_ssh/readme.html for general SSH configuration
# * See https://hexdocs.pm/ssh_subsystem_fwup/readme.html for firmware updates

# Uncomment and add your SSH public keys:
# config :nerves_ssh,
#   authorized_keys: [
#     File.read!(Path.join(System.user_home!(), ".ssh/id_ed25519.pub"))
#   ]

keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()

if keys != [] do
  config :nerves_ssh,
    authorized_keys: Enum.map(keys, &File.read!/1)
end

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"wlan0", %{type: VintageNetWiFi}}
    # To connect to WiFi, change the above to:
    # {"wlan0",
    #  %{
    #    type: VintageNetWiFi,
    #    vintage_net_wifi: %{
    #      networks: [
    #        %{
    #          key_mgmt: :wpa_psk,
    #          ssid: "your_ssid",
    #          psk: "your_password"
    #        }
    #      ]
    #    },
    #    ipv4: %{method: :dhcp}
    #  }}
  ]

config :mdns_lite,
  hosts: [:hostname, "nerves"],
  ttl: 120,
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    }
  ]

# BlueHeron UART transport for onboard Broadcom Bluetooth
# Pi Zero 2W uses /dev/ttyS0 at 115200 baud
config :blue_heron,
  transport: [
    device: "/dev/ttyS0",
    speed: 115_200
  ]

# import_config "#{Mix.target()}.exs"
