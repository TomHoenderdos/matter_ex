defmodule NervesLight.Device do
  @moduledoc """
  Matter device definition for the Nerves Light.

  Defines a Dimmable Light (device type 0x0100) with OnOff and LevelControl clusters.
  """

  use MatterEx.Device,
    vendor_name: "MatterEx",
    product_name: "Nerves Light",
    vendor_id: 0xFFF1,
    product_id: 0x8000

  endpoint 1, device_type: 0x0100 do
    cluster MatterEx.Cluster.OnOff
    cluster MatterEx.Cluster.LevelControl
  end
end
