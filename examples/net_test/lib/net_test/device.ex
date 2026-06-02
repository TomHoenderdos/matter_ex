defmodule NetTest.Device do
  use MatterEx.Device,
    vendor_name: "MatterEx",
    product_name: "Net Test Light",
    vendor_id: 0xFFF1,
    product_id: 0x8000

  endpoint 1, device_type: 0x0101 do
    cluster(MatterEx.Cluster.Identify)
    cluster(MatterEx.Cluster.Groups)
    cluster(MatterEx.Cluster.Scenes)
    cluster(MatterEx.Cluster.OnOff)
    cluster(MatterEx.Cluster.LevelControl)
  end
end
