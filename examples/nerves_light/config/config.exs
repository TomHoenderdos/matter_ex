import Config

config :nerves_light,
  discriminator: 3840,
  passcode: 20202021,
  vendor_id: 0xFFF1,
  product_id: 0x8000

# config_target() requires nerves_bootstrap archive to be installed.
# On host, it returns :host; on target, it returns :rpi3/:rpi4/etc.
if config_target() != :host do
  import_config "target.exs"
else
  import_config "host.exs"
end
