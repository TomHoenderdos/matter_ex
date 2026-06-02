defmodule NetTest.Device do
  use MatterEx.Device,
    vendor_name: "MatterEx",
    product_name: "Net Test Light + Sensor",
    vendor_id: 0xFFF1,
    product_id: 0x8000

  endpoint 1, device_type: 0x0101 do
    cluster(MatterEx.Cluster.Identify)
    cluster(MatterEx.Cluster.Groups)
    cluster(MatterEx.Cluster.Scenes)
    cluster(MatterEx.Cluster.OnOff)
    cluster(MatterEx.Cluster.LevelControl)
  end

  endpoint 2, device_type: 0x0302 do
    cluster(MatterEx.Cluster.Identify)
    cluster(MatterEx.Cluster.TemperatureMeasurement)
  end

  endpoint 3, device_type: 0x0307 do
    cluster(MatterEx.Cluster.Identify)
    cluster(MatterEx.Cluster.RelativeHumidityMeasurement)
  end

  endpoint 4, device_type: 0x0106 do
    cluster(MatterEx.Cluster.Identify)
    cluster(MatterEx.Cluster.IlluminanceMeasurement)
  end

  endpoint 5, device_type: 0x0107 do
    cluster(MatterEx.Cluster.Identify)
    cluster(MatterEx.Cluster.OccupancySensing)
  end

  endpoint 6, device_type: 0x0015 do
    cluster(MatterEx.Cluster.Identify)
    cluster(MatterEx.Cluster.BooleanState)
  end

  endpoint 7, device_type: 0x002C do
    cluster(MatterEx.Cluster.Identify)
    cluster(MatterEx.Cluster.AirQuality)
  end
end
