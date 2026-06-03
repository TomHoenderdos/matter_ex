# Advanced Matter IDs

MatterEx exposes named DSL helpers for common clusters, attributes, commands,
device types, vendors, and development products. Prefer those names for app code:

```elixir
defmodule MyApp.Light do
  use MatterEx.Device,
    vendor: :test,
    product: :smart_light

  endpoint :light, :dimmable_light
end
```

Use raw Matter IDs when you are implementing a custom cluster, a vendor-specific
extension, or a specification item that MatterEx does not know yet.

## Device Metadata

```elixir
defmodule MyApp.CustomDevice do
  use MatterEx.Device,
    vendor_name: "Acme",
    product_name: "Custom Sensor",
    vendor_id: 0xFFF1,
    product_id: 0x8001

  endpoint 1, device_type: 0x0302 do
    cluster MatterEx.Cluster.TemperatureMeasurement
  end
end
```

Named endpoint definitions auto-compose required clusters. Numeric endpoint
definitions preserve the old explicit behavior:

```elixir
endpoint :temperature, :temperature_sensor

endpoint 1, device_type: 0x0302 do
  cluster MatterEx.Cluster.Identify
  cluster MatterEx.Cluster.TemperatureMeasurement
end
```

## Clusters

```elixir
defmodule MyApp.Cluster.VendorSpecific do
  use MatterEx.Cluster, id: 0xFC00, name: :vendor_specific

  attribute 0x0000, :enabled, :boolean, default: false, writable: true

  command 0x00, :reset, []
end
```

For built-in clusters, the ID can be resolved from the name:

```elixir
defmodule MyApp.Cluster.OnOff do
  use MatterEx.Cluster, :on_off
end
```

Built-in cluster names infer `cluster_revision` automatically. For custom
clusters, MatterEx defaults it to `1`; use `revision 2` only when your custom
cluster needs a different value.

Built-in cluster names infer their standard attributes. Use `attribute` only
when adding custom attributes or overriding a known attribute's metadata.

Declare commands that your custom cluster module implements. Built-in command
names resolve their Matter IDs automatically, for example `command :on` in an
`:on_off` cluster. Use raw command IDs only for custom or vendor-specific
commands.

Look up known names from IEx:

```elixir
MatterEx.Cluster.known_clusters()
MatterEx.DeviceTypes.known_device_types()
MatterEx.Device.known_vendors()
MatterEx.Device.known_products()
```
