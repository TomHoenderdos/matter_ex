defmodule MatterEx.DeviceTypesTest do
  use ExUnit.Case, async: true

  alias MatterEx.DeviceTypes

  describe "get/1" do
    test "returns device type for known ID" do
      dt = DeviceTypes.get(0x0100)
      assert dt.name == :on_off_light
      assert dt.id == 0x0100
      assert dt.revision == 3
      # Descriptor
      assert 0x001D in dt.required_clusters
      # OnOff
      assert 0x0006 in dt.required_clusters
    end

    test "returns nil for unknown ID" do
      assert DeviceTypes.get(0xFFFF) == nil
    end

    test "root node includes required endpoint 0 clusters" do
      dt = DeviceTypes.get(0x0016)
      assert dt.name == :root_node
      # OperationalCredentials
      assert 0x003E in dt.required_clusters
      # GeneralDiagnostics
      assert 0x0033 in dt.required_clusters
      # AccessControl
      assert 0x001F in dt.required_clusters
      # GeneralCommissioning
      assert 0x0030 in dt.required_clusters
      # AdministratorCommissioning
      assert 0x003C in dt.required_clusters
    end

    test "thermostat device type" do
      dt = DeviceTypes.get(0x0301)
      assert dt.name == :thermostat
      # Thermostat cluster
      assert 0x0201 in dt.required_clusters
      # FanControl is optional
      assert 0x0202 in dt.optional_clusters
    end
  end

  describe "list/0" do
    test "returns list of all device type IDs" do
      ids = DeviceTypes.list()
      assert is_list(ids)
      # On/Off Light
      assert 0x0100 in ids
      # Root Node
      assert 0x0016 in ids
      assert length(ids) > 20
    end
  end

  describe "known_device_types/0" do
    test "returns sorted device type names and IDs" do
      device_types = DeviceTypes.known_device_types()

      assert Keyword.keyword?(device_types)
      assert device_types == Enum.sort_by(device_types, &elem(&1, 0))
      assert device_types[:on_off_light] == 0x0100
      assert device_types[:root_node] == 0x0016
      assert length(device_types) == length(DeviceTypes.list())
    end
  end

  describe "id_for_name/1" do
    test "returns ID for known device type name" do
      assert DeviceTypes.id_for_name(:on_off_light) == 0x0100
      assert DeviceTypes.id_for_name(:door_lock) == 0x000A
      assert DeviceTypes.id_for_name(:thermostat) == 0x0301
    end

    test "returns nil for unknown device type name" do
      assert DeviceTypes.id_for_name(:unknown_device_type) == nil
    end
  end

  describe "name/1" do
    test "returns name for known device type" do
      assert DeviceTypes.name(0x0100) == :on_off_light
      assert DeviceTypes.name(0x000A) == :door_lock
      assert DeviceTypes.name(0x0301) == :thermostat
    end

    test "returns nil for unknown device type" do
      assert DeviceTypes.name(0xFFFF) == nil
    end
  end

  describe "validate/2" do
    test "passes when all required clusters are present" do
      # On/Off Light requires: Descriptor, Identify, Groups, Scenes, OnOff
      cluster_ids = [0x001D, 0x0003, 0x0004, 0x0005, 0x0006, 0x0008]
      assert :ok = DeviceTypes.validate(0x0100, cluster_ids)
    end

    test "fails when required clusters are missing" do
      # Missing OnOff (0x0006)
      cluster_ids = [0x001D, 0x0003, 0x0004, 0x0005]
      assert {:error, missing} = DeviceTypes.validate(0x0100, cluster_ids)
      assert 0x0006 in missing
    end

    test "passes for unknown device type" do
      assert :ok = DeviceTypes.validate(0xFFFF, [])
    end

    test "door lock requires DoorLock cluster" do
      # Door Lock: Descriptor + Identify + DoorLock
      cluster_ids = [0x001D, 0x0003, 0x0101]
      assert :ok = DeviceTypes.validate(0x000A, cluster_ids)
    end

    test "door lock without DoorLock cluster fails" do
      cluster_ids = [0x001D, 0x0003]
      assert {:error, missing} = DeviceTypes.validate(0x000A, cluster_ids)
      assert 0x0101 in missing
    end

    test "contact sensor requires BooleanState" do
      cluster_ids = [0x001D, 0x0003, 0x0045]
      assert :ok = DeviceTypes.validate(0x0015, cluster_ids)
    end
  end
end
