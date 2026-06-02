defmodule NetTestTest do
  use ExUnit.Case
  doctest NetTest

  test "device exposes light and fake sensor endpoints" do
    assert MapSet.member?(NetTest.Device.__endpoint_ids__(), 1)
    assert MapSet.member?(NetTest.Device.__endpoint_ids__(), 2)
    assert MapSet.member?(NetTest.Device.__endpoint_ids__(), 3)
    assert MapSet.member?(NetTest.Device.__endpoint_ids__(), 4)
    assert MapSet.member?(NetTest.Device.__endpoint_ids__(), 5)
    assert MapSet.member?(NetTest.Device.__endpoint_ids__(), 6)
    assert MapSet.member?(NetTest.Device.__endpoint_ids__(), 7)
    assert MatterEx.Cluster.LevelControl.cluster_id() in NetTest.Device.__cluster_ids__(1)

    assert MatterEx.Cluster.TemperatureMeasurement.cluster_id() in NetTest.Device.__cluster_ids__(
             2
           )

    assert MatterEx.Cluster.RelativeHumidityMeasurement.cluster_id() in NetTest.Device.__cluster_ids__(
             3
           )

    assert MatterEx.Cluster.IlluminanceMeasurement.cluster_id() in NetTest.Device.__cluster_ids__(
             4
           )

    assert MatterEx.Cluster.OccupancySensing.cluster_id() in NetTest.Device.__cluster_ids__(5)
    assert MatterEx.Cluster.BooleanState.cluster_id() in NetTest.Device.__cluster_ids__(6)
    assert MatterEx.Cluster.AirQuality.cluster_id() in NetTest.Device.__cluster_ids__(7)
  end

  test "fake sensor values cycle in Matter units" do
    assert NetTest.FakeSensor.fake_temperature(2100, 0) == 2100
    assert NetTest.FakeSensor.fake_temperature(2100, 1) == 2125
    assert NetTest.FakeSensor.fake_temperature(2100, 12) == 2100
    assert NetTest.FakeSensor.fake_temperature(2100, 13) == 2075

    assert NetTest.FakeSensor.fake_humidity(4500, 0) == 4500
    assert NetTest.FakeSensor.fake_humidity(4500, 1) == 4650
    assert NetTest.FakeSensor.fake_humidity(4500, 10) == 4500
    assert NetTest.FakeSensor.fake_humidity(4500, 11) == 4350

    assert NetTest.FakeSensor.fake_illuminance(100, 0) == 20_001
    assert NetTest.FakeSensor.fake_occupancy(0) == 1
    assert NetTest.FakeSensor.fake_occupancy(2) == 0
    assert NetTest.FakeSensor.fake_contact_open(3) == true
    assert NetTest.FakeSensor.fake_contact_open(6) == false
    assert NetTest.FakeSensor.fake_air_quality(0) == 1
    assert NetTest.FakeSensor.fake_air_quality(4) == 5
  end
end
