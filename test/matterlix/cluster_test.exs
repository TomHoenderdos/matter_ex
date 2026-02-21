defmodule Matterlix.ClusterTest do
  use ExUnit.Case, async: true

  alias Matterlix.Cluster.OnOff
  alias Matterlix.Cluster.Descriptor
  alias Matterlix.Cluster.BasicInformation
  alias Matterlix.Cluster.LevelControl
  alias Matterlix.Cluster.ColorControl
  alias Matterlix.Cluster.TemperatureMeasurement
  alias Matterlix.Cluster.BooleanState
  alias Matterlix.Cluster.Thermostat
  alias Matterlix.Cluster.AccessControl
  alias Matterlix.Cluster.GeneralCommissioning
  alias Matterlix.Cluster.GroupKeyManagement
  alias Matterlix.Cluster.NetworkCommissioning
  alias Matterlix.Cluster.OperationalCredentials
  alias Matterlix.Cluster.Identify
  alias Matterlix.Cluster.Binding
  alias Matterlix.Cluster.PowerSource
  alias Matterlix.Cluster.Scenes
  alias Matterlix.Cluster.Groups
  alias Matterlix.Cluster.DoorLock
  alias Matterlix.Cluster.WindowCovering
  alias Matterlix.Cluster.FanControl
  alias Matterlix.Cluster.OccupancySensing
  alias Matterlix.Cluster.IlluminanceMeasurement
  alias Matterlix.Cluster.RelativeHumidityMeasurement
  alias Matterlix.Cluster.PressureMeasurement
  alias Matterlix.Cluster.FlowMeasurement
  alias Matterlix.Cluster.PumpConfigurationAndControl
  alias Matterlix.Cluster.GeneralDiagnostics
  alias Matterlix.Cluster.SoftwareDiagnostics
  alias Matterlix.Cluster.WiFiNetworkDiagnostics
  alias Matterlix.Cluster.EthernetNetworkDiagnostics
  alias Matterlix.Cluster.AdminCommissioning
  alias Matterlix.Cluster.LocalizationConfiguration
  alias Matterlix.Cluster.TimeFormatLocalization
  alias Matterlix.Cluster.UnitLocalization
  alias Matterlix.Cluster.TimeSynchronization
  alias Matterlix.Cluster.Switch
  alias Matterlix.Cluster.ModeSelect
  alias Matterlix.Cluster.FixedLabel
  alias Matterlix.Cluster.UserLabel
  alias Matterlix.Cluster.OTASoftwareUpdateProvider
  alias Matterlix.Cluster.OTASoftwareUpdateRequestor
  alias Matterlix.Cluster.ElectricalMeasurement
  alias Matterlix.Cluster.PowerTopology
  alias Matterlix.Cluster.AirQuality
  alias Matterlix.Cluster.PM25ConcentrationMeasurement
  alias Matterlix.Cluster.CarbonDioxideConcentrationMeasurement
  alias Matterlix.Cluster.ICDManagement
  alias Matterlix.Cluster.DeviceEnergyManagement
  alias Matterlix.Cluster.EnergyPreference
  alias Matterlix.Commissioning

  # ── Cluster macro metadata ────────────────────────────────────

  describe "cluster metadata" do
    test "OnOff cluster_id and name" do
      assert OnOff.cluster_id() == 0x0006
      assert OnOff.cluster_name() == :on_off
    end

    test "OnOff attribute_defs" do
      defs = OnOff.attribute_defs()
      assert length(defs) == 7

      on_off_attr = Enum.find(defs, &(&1.name == :on_off))
      assert on_off_attr.id == 0x0000
      assert on_off_attr.type == :boolean
      assert on_off_attr.default == false
      assert on_off_attr.writable == true

      rev_attr = Enum.find(defs, &(&1.name == :cluster_revision))
      assert rev_attr.id == 0xFFFD
      assert rev_attr.writable == false
    end

    test "OnOff global attributes auto-generated" do
      defs = OnOff.attribute_defs()

      # FeatureMap
      feature_map = Enum.find(defs, &(&1.id == 0xFFFC))
      assert feature_map.name == :feature_map
      assert feature_map.default == 0
      assert feature_map.writable == false

      # AcceptedCommandList
      accepted = Enum.find(defs, &(&1.id == 0xFFF9))
      assert accepted.name == :accepted_command_list
      assert accepted.default == [0x00, 0x01, 0x02]

      # GeneratedCommandList (no response_ids defined)
      generated = Enum.find(defs, &(&1.id == 0xFFF8))
      assert generated.name == :generated_command_list
      assert generated.default == []

      # AttributeList (all attribute IDs sorted)
      attr_list = Enum.find(defs, &(&1.id == 0xFFFB))
      assert attr_list.name == :attribute_list
      expected_ids = Enum.map(defs, & &1.id) |> Enum.sort()
      assert attr_list.default == expected_ids
    end

    test "OnOff command_defs" do
      defs = OnOff.command_defs()
      assert length(defs) == 3
      assert Enum.find(defs, &(&1.name == :off)).id == 0x00
      assert Enum.find(defs, &(&1.name == :on)).id == 0x01
      assert Enum.find(defs, &(&1.name == :toggle)).id == 0x02
    end

    test "Descriptor cluster_id and name" do
      assert Descriptor.cluster_id() == 0x001D
      assert Descriptor.cluster_name() == :descriptor
    end

    test "BasicInformation cluster_id and name" do
      assert BasicInformation.cluster_id() == 0x0028
      assert BasicInformation.cluster_name() == :basic_information
    end

    test "LevelControl cluster_id and name" do
      assert LevelControl.cluster_id() == 0x0008
      assert LevelControl.cluster_name() == :level_control
    end

    test "LevelControl attribute_defs" do
      defs = LevelControl.attribute_defs()
      assert length(defs) == 10

      level = Enum.find(defs, &(&1.name == :current_level))
      assert level.id == 0x0000
      assert level.type == :uint8
      assert level.default == 0
      assert level.writable == true

      assert Enum.find(defs, &(&1.name == :min_level)).default == 1
      assert Enum.find(defs, &(&1.name == :max_level)).default == 254
    end

    test "LevelControl command_defs" do
      defs = LevelControl.command_defs()
      assert length(defs) == 2
      assert Enum.find(defs, &(&1.name == :move_to_level)).id == 0x00
      assert Enum.find(defs, &(&1.name == :move_to_level_with_on_off)).id == 0x04
    end

    test "ColorControl cluster_id and name" do
      assert ColorControl.cluster_id() == 0x0300
      assert ColorControl.cluster_name() == :color_control
    end

    test "ColorControl attribute_defs" do
      defs = ColorControl.attribute_defs()
      assert length(defs) == 15

      assert Enum.find(defs, &(&1.name == :current_hue)).writable == true
      assert Enum.find(defs, &(&1.name == :color_mode)).writable == false
      assert Enum.find(defs, &(&1.name == :color_capabilities)).default == 0x001F
    end

    test "ColorControl command_defs" do
      defs = ColorControl.command_defs()
      assert length(defs) == 4
      assert Enum.find(defs, &(&1.name == :move_to_hue)).id == 0x00
      assert Enum.find(defs, &(&1.name == :move_to_saturation)).id == 0x03
      assert Enum.find(defs, &(&1.name == :move_to_color)).id == 0x07
      assert Enum.find(defs, &(&1.name == :move_to_color_temperature)).id == 0x0A
    end

    test "TemperatureMeasurement cluster_id and name" do
      assert TemperatureMeasurement.cluster_id() == 0x0402
      assert TemperatureMeasurement.cluster_name() == :temperature_measurement
    end

    test "TemperatureMeasurement attribute_defs" do
      defs = TemperatureMeasurement.attribute_defs()
      assert length(defs) == 10
      assert Enum.find(defs, &(&1.name == :measured_value)).default == 2000
      assert Enum.find(defs, &(&1.name == :measured_value)).writable == false
    end

    test "TemperatureMeasurement has no commands" do
      assert TemperatureMeasurement.command_defs() == []
    end

    test "BooleanState cluster_id and name" do
      assert BooleanState.cluster_id() == 0x0045
      assert BooleanState.cluster_name() == :boolean_state
    end

    test "BooleanState attribute_defs" do
      defs = BooleanState.attribute_defs()
      assert length(defs) == 7
      assert Enum.find(defs, &(&1.name == :state_value)).default == false
      assert Enum.find(defs, &(&1.name == :state_value)).writable == false
    end

    test "BooleanState has no commands" do
      assert BooleanState.command_defs() == []
    end

    test "Thermostat cluster_id and name" do
      assert Thermostat.cluster_id() == 0x0201
      assert Thermostat.cluster_name() == :thermostat
    end

    test "Thermostat attribute_defs" do
      defs = Thermostat.attribute_defs()
      assert length(defs) == 15

      heat = Enum.find(defs, &(&1.name == :occupied_heating_setpoint))
      assert heat.id == 0x0012
      assert heat.default == 2000
      assert heat.writable == true

      assert Enum.find(defs, &(&1.name == :system_mode)).writable == true
      assert Enum.find(defs, &(&1.name == :local_temperature)).writable == false
    end

    test "Thermostat command_defs" do
      defs = Thermostat.command_defs()
      assert length(defs) == 1
      assert Enum.find(defs, &(&1.name == :setpoint_raise_lower)).id == 0x00
    end

    test "GeneralCommissioning cluster_id and name" do
      assert GeneralCommissioning.cluster_id() == 0x0030
      assert GeneralCommissioning.cluster_name() == :general_commissioning
    end

    test "GeneralCommissioning generated_command_list from response_ids" do
      defs = GeneralCommissioning.attribute_defs()
      generated = Enum.find(defs, &(&1.id == 0xFFF8))
      assert generated.default == [0x01, 0x03, 0x05]
    end

    test "GeneralCommissioning command_defs" do
      defs = GeneralCommissioning.command_defs()
      assert length(defs) == 3
      assert Enum.find(defs, &(&1.name == :arm_fail_safe)).id == 0x00
      assert Enum.find(defs, &(&1.name == :set_regulatory_config)).id == 0x02
      assert Enum.find(defs, &(&1.name == :commissioning_complete)).id == 0x04
    end

    test "OperationalCredentials cluster_id and name" do
      assert OperationalCredentials.cluster_id() == 0x003E
      assert OperationalCredentials.cluster_name() == :operational_credentials
    end

    test "OperationalCredentials command_defs" do
      defs = OperationalCredentials.command_defs()
      assert length(defs) == 5
      assert Enum.find(defs, &(&1.name == :csr_request)).id == 0x04
      assert Enum.find(defs, &(&1.name == :add_noc)).id == 0x06
      assert Enum.find(defs, &(&1.name == :remove_fabric)).id == 0x0A
      assert Enum.find(defs, &(&1.name == :update_fabric_label)).id == 0x09
      assert Enum.find(defs, &(&1.name == :add_trusted_root_cert)).id == 0x0B
    end

    test "OperationalCredentials attribute defaults" do
      defs = OperationalCredentials.attribute_defs()
      assert Enum.find(defs, &(&1.name == :supported_fabrics)).default == 5
      assert Enum.find(defs, &(&1.name == :commissioned_fabrics)).default == 0
    end
  end

  # ── Event declarations ───────────────────────────────────────

  describe "event declarations" do
    test "OnOff has no events" do
      assert OnOff.event_defs() == []
    end

    test "BasicInformation has start_up and shut_down events" do
      defs = BasicInformation.event_defs()
      assert length(defs) == 2

      start_up = Enum.find(defs, &(&1.name == :start_up))
      assert start_up.id == 0x00
      assert start_up.priority == 2

      shut_down = Enum.find(defs, &(&1.name == :shut_down))
      assert shut_down.id == 0x01
      assert shut_down.priority == 2
    end

    test "OnOff event_list global attribute is empty" do
      defs = OnOff.attribute_defs()
      event_list = Enum.find(defs, &(&1.id == 0xFFFA))
      assert event_list.name == :event_list
      assert event_list.default == []
    end

    test "BasicInformation event_list contains event IDs" do
      defs = BasicInformation.attribute_defs()
      event_list = Enum.find(defs, &(&1.id == 0xFFFA))
      assert event_list.name == :event_list
      assert event_list.default == [0x00, 0x01]
    end
  end

  # ── OnOff GenServer ───────────────────────────────────────────

  describe "OnOff GenServer" do
    setup do
      name = :"on_off_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = OnOff.start_link(name: name)
      %{pid: pid, name: name}
    end

    test "initial state defaults", %{name: name} do
      assert {:ok, false} = GenServer.call(name, {:read_attribute, :on_off})
      assert {:ok, 4} = GenServer.call(name, {:read_attribute, :cluster_revision})
    end

    test "read unknown attribute", %{name: name} do
      assert {:error, :unsupported_attribute} =
               GenServer.call(name, {:read_attribute, :bogus})
    end

    test "write writable attribute", %{name: name} do
      assert :ok = GenServer.call(name, {:write_attribute, :on_off, true})
      assert {:ok, true} = GenServer.call(name, {:read_attribute, :on_off})
    end

    test "write read-only attribute fails", %{name: name} do
      assert {:error, :unsupported_write} =
               GenServer.call(name, {:write_attribute, :cluster_revision, 99})
    end

    test "write unknown attribute fails", %{name: name} do
      assert {:error, :unsupported_attribute} =
               GenServer.call(name, {:write_attribute, :bogus, 1})
    end

    test "invoke :on command", %{name: name} do
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :on, %{}})
      assert {:ok, true} = GenServer.call(name, {:read_attribute, :on_off})
    end

    test "invoke :off command", %{name: name} do
      GenServer.call(name, {:invoke_command, :on, %{}})
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :off, %{}})
      assert {:ok, false} = GenServer.call(name, {:read_attribute, :on_off})
    end

    test "invoke :toggle command", %{name: name} do
      assert {:ok, false} = GenServer.call(name, {:read_attribute, :on_off})
      GenServer.call(name, {:invoke_command, :toggle, %{}})
      assert {:ok, true} = GenServer.call(name, {:read_attribute, :on_off})
      GenServer.call(name, {:invoke_command, :toggle, %{}})
      assert {:ok, false} = GenServer.call(name, {:read_attribute, :on_off})
    end

    test "invoke unknown command fails", %{name: name} do
      assert {:error, :unsupported_command} =
               GenServer.call(name, {:invoke_command, :bogus, %{}})
    end
  end

  # ── DataVersion Tracking ─────────────────────────────────────

  describe "DataVersion tracking" do
    setup do
      name = :"on_off_dv_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = OnOff.start_link(name: name)
      %{pid: pid, name: name}
    end

    test "initial data_version is 0", %{name: name} do
      assert 0 = GenServer.call(name, :read_data_version)
    end

    test "write_attribute bumps data_version", %{name: name} do
      assert 0 = GenServer.call(name, :read_data_version)
      :ok = GenServer.call(name, {:write_attribute, :on_off, true})
      assert 1 = GenServer.call(name, :read_data_version)
      :ok = GenServer.call(name, {:write_attribute, :on_off, false})
      assert 2 = GenServer.call(name, :read_data_version)
    end

    test "invoke_command bumps data_version when state changes", %{name: name} do
      assert 0 = GenServer.call(name, :read_data_version)
      {:ok, nil} = GenServer.call(name, {:invoke_command, :on, %{}})
      assert 1 = GenServer.call(name, :read_data_version)
    end

    test "invoke_command does not bump when state is unchanged", %{name: name} do
      # on_off starts as false, :off is a no-op
      assert 0 = GenServer.call(name, :read_data_version)
      {:ok, nil} = GenServer.call(name, {:invoke_command, :off, %{}})
      assert 0 = GenServer.call(name, :read_data_version)
    end

    test "failed write does not bump data_version", %{name: name} do
      assert 0 = GenServer.call(name, :read_data_version)
      {:error, :unsupported_write} = GenServer.call(name, {:write_attribute, :cluster_revision, 99})
      assert 0 = GenServer.call(name, :read_data_version)
    end
  end

  # ── Descriptor GenServer ──────────────────────────────────────

  describe "Descriptor GenServer" do
    setup do
      name = :"descriptor_test_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Descriptor.start_link(
          name: name,
          device_type_list: [%{device_type: 0x0100, revision: 1}],
          server_list: [0x0006, 0x001D],
          parts_list: [1, 2]
        )

      %{pid: pid, name: name}
    end

    test "init populates from opts", %{name: name} do
      assert {:ok, [%{device_type: 0x0100, revision: 1}]} =
               GenServer.call(name, {:read_attribute, :device_type_list})

      assert {:ok, [0x0006, 0x001D]} =
               GenServer.call(name, {:read_attribute, :server_list})

      assert {:ok, [1, 2]} =
               GenServer.call(name, {:read_attribute, :parts_list})
    end
  end

  # ── BasicInformation GenServer ────────────────────────────────

  describe "BasicInformation GenServer" do
    setup do
      name = :"basic_info_test_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        BasicInformation.start_link(
          name: name,
          vendor_name: "TestCo",
          vendor_id: 0xFFF1,
          product_name: "TestLight",
          product_id: 0x8001
        )

      %{pid: pid, name: name}
    end

    test "init populates from opts", %{name: name} do
      assert {:ok, "TestCo"} =
               GenServer.call(name, {:read_attribute, :vendor_name})

      assert {:ok, 0xFFF1} =
               GenServer.call(name, {:read_attribute, :vendor_id})

      assert {:ok, "TestLight"} =
               GenServer.call(name, {:read_attribute, :product_name})

      assert {:ok, 0x8001} =
               GenServer.call(name, {:read_attribute, :product_id})
    end

    test "node_label is writable", %{name: name} do
      assert :ok = GenServer.call(name, {:write_attribute, :node_label, "my light"})
      assert {:ok, "my light"} = GenServer.call(name, {:read_attribute, :node_label})
    end

    test "vendor_name is read-only", %{name: name} do
      assert {:error, :unsupported_write} =
               GenServer.call(name, {:write_attribute, :vendor_name, "hack"})
    end
  end

  # ── LevelControl GenServer ─────────────────────────────────────

  describe "LevelControl GenServer" do
    setup do
      name = :"level_control_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = LevelControl.start_link(name: name)
      %{pid: pid, name: name}
    end

    test "initial state defaults", %{name: name} do
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :current_level})
      assert {:ok, 255} = GenServer.call(name, {:read_attribute, :on_level})
    end

    test "move_to_level sets current_level", %{name: name} do
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :move_to_level, %{level: 128}})
      assert {:ok, 128} = GenServer.call(name, {:read_attribute, :current_level})
    end

    test "move_to_level clamps to min/max", %{name: name} do
      # Below min (1) → clamps to 1
      GenServer.call(name, {:invoke_command, :move_to_level, %{level: 0}})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :current_level})

      # Above max (254) → clamps to 254
      GenServer.call(name, {:invoke_command, :move_to_level, %{level: 255}})
      assert {:ok, 254} = GenServer.call(name, {:read_attribute, :current_level})
    end

    test "move_to_level_with_on_off works", %{name: name} do
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :move_to_level_with_on_off, %{level: 200}})
      assert {:ok, 200} = GenServer.call(name, {:read_attribute, :current_level})
    end

    test "write on_level", %{name: name} do
      assert :ok = GenServer.call(name, {:write_attribute, :on_level, 100})
      assert {:ok, 100} = GenServer.call(name, {:read_attribute, :on_level})
    end
  end

  # ── ColorControl GenServer ─────────────────────────────────────

  describe "ColorControl GenServer" do
    setup do
      name = :"color_control_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = ColorControl.start_link(name: name)
      %{pid: pid, name: name}
    end

    test "move_to_hue sets hue and color_mode=0", %{name: name} do
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :move_to_hue, %{hue: 120}})
      assert {:ok, 120} = GenServer.call(name, {:read_attribute, :current_hue})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :color_mode})
    end

    test "move_to_saturation sets saturation and color_mode=0", %{name: name} do
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :move_to_saturation, %{saturation: 200}})
      assert {:ok, 200} = GenServer.call(name, {:read_attribute, :current_saturation})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :color_mode})
    end

    test "move_to_color sets x/y and color_mode=1", %{name: name} do
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :move_to_color, %{color_x: 1000, color_y: 2000}})
      assert {:ok, 1000} = GenServer.call(name, {:read_attribute, :current_x})
      assert {:ok, 2000} = GenServer.call(name, {:read_attribute, :current_y})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :color_mode})
    end

    test "move_to_color_temperature sets temp and color_mode=2", %{name: name} do
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :move_to_color_temperature, %{color_temperature: 300}})
      assert {:ok, 300} = GenServer.call(name, {:read_attribute, :color_temperature})
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :color_mode})
    end

    test "move_to_color_temperature clamps to min/max", %{name: name} do
      # Below min (153) → clamps to 153
      GenServer.call(name, {:invoke_command, :move_to_color_temperature, %{color_temperature: 50}})
      assert {:ok, 153} = GenServer.call(name, {:read_attribute, :color_temperature})

      # Above max (500) → clamps to 500
      GenServer.call(name, {:invoke_command, :move_to_color_temperature, %{color_temperature: 1000}})
      assert {:ok, 500} = GenServer.call(name, {:read_attribute, :color_temperature})
    end

    test "color_mode is read-only", %{name: name} do
      assert {:error, :unsupported_write} =
               GenServer.call(name, {:write_attribute, :color_mode, 1})
    end
  end

  # ── TemperatureMeasurement GenServer ───────────────────────────

  describe "TemperatureMeasurement GenServer" do
    setup do
      name = :"temp_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = TemperatureMeasurement.start_link(name: name)
      %{pid: pid, name: name}
    end

    test "default measured_value is 2000", %{name: name} do
      assert {:ok, 2000} = GenServer.call(name, {:read_attribute, :measured_value})
    end

    test "read all attributes", %{name: name} do
      assert {:ok, -5000} = GenServer.call(name, {:read_attribute, :min_measured_value})
      assert {:ok, 12500} = GenServer.call(name, {:read_attribute, :max_measured_value})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :tolerance})
    end

    test "measured_value is read-only", %{name: name} do
      assert {:error, :unsupported_write} =
               GenServer.call(name, {:write_attribute, :measured_value, 2500})
    end
  end

  # ── BooleanState GenServer ─────────────────────────────────────

  describe "BooleanState GenServer" do
    setup do
      name = :"bool_state_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = BooleanState.start_link(name: name)
      %{pid: pid, name: name}
    end

    test "default state_value is false", %{name: name} do
      assert {:ok, false} = GenServer.call(name, {:read_attribute, :state_value})
    end

    test "state_value is read-only", %{name: name} do
      assert {:error, :unsupported_write} =
               GenServer.call(name, {:write_attribute, :state_value, true})
    end

    test "invoke unknown command fails", %{name: name} do
      assert {:error, :unsupported_command} =
               GenServer.call(name, {:invoke_command, :bogus, %{}})
    end
  end

  # ── Thermostat GenServer ───────────────────────────────────────

  describe "Thermostat GenServer" do
    setup do
      name = :"thermostat_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = Thermostat.start_link(name: name)
      %{pid: pid, name: name}
    end

    test "initial state defaults", %{name: name} do
      assert {:ok, 2000} = GenServer.call(name, {:read_attribute, :local_temperature})
      assert {:ok, 2000} = GenServer.call(name, {:read_attribute, :occupied_heating_setpoint})
      assert {:ok, 2600} = GenServer.call(name, {:read_attribute, :occupied_cooling_setpoint})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :system_mode})
    end

    test "write system_mode", %{name: name} do
      assert :ok = GenServer.call(name, {:write_attribute, :system_mode, 4})
      assert {:ok, 4} = GenServer.call(name, {:read_attribute, :system_mode})
    end

    test "write heating setpoint", %{name: name} do
      assert :ok = GenServer.call(name, {:write_attribute, :occupied_heating_setpoint, 2200})
      assert {:ok, 2200} = GenServer.call(name, {:read_attribute, :occupied_heating_setpoint})
    end

    test "local_temperature is read-only", %{name: name} do
      assert {:error, :unsupported_write} =
               GenServer.call(name, {:write_attribute, :local_temperature, 2500})
    end

    test "setpoint_raise_lower heat mode raises heating setpoint", %{name: name} do
      # mode=0 (heat), amount=2 → +20 (0.2°C in 0.01°C units)
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :setpoint_raise_lower, %{mode: 0, amount: 2}})
      assert {:ok, 2020} = GenServer.call(name, {:read_attribute, :occupied_heating_setpoint})
    end

    test "setpoint_raise_lower cool mode raises cooling setpoint", %{name: name} do
      # mode=1 (cool), amount=-3 → -30
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :setpoint_raise_lower, %{mode: 1, amount: -3}})
      assert {:ok, 2570} = GenServer.call(name, {:read_attribute, :occupied_cooling_setpoint})
    end

    test "setpoint_raise_lower both mode raises both setpoints", %{name: name} do
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :setpoint_raise_lower, %{mode: 2, amount: 5}})
      assert {:ok, 2050} = GenServer.call(name, {:read_attribute, :occupied_heating_setpoint})
      assert {:ok, 2650} = GenServer.call(name, {:read_attribute, :occupied_cooling_setpoint})
    end

    test "setpoint_raise_lower clamps to abs limits", %{name: name} do
      # Try to lower heating below abs_min_heat (700)
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :setpoint_raise_lower, %{mode: 0, amount: -200}})
      assert {:ok, 700} = GenServer.call(name, {:read_attribute, :occupied_heating_setpoint})

      # Try to raise cooling above abs_max_cool (3200)
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :setpoint_raise_lower, %{mode: 1, amount: 100}})
      assert {:ok, 3200} = GenServer.call(name, {:read_attribute, :occupied_cooling_setpoint})
    end
  end

  # ── AccessControl metadata ────────────────────────────────────

  describe "AccessControl metadata" do
    test "cluster_id and name" do
      assert AccessControl.cluster_id() == 0x001F
      assert AccessControl.cluster_name() == :access_control
    end

    test "attribute_defs" do
      defs = AccessControl.attribute_defs()
      acl_attr = Enum.find(defs, &(&1.name == :acl))
      assert acl_attr.id == 0x0000
      assert acl_attr.default == []
      assert acl_attr.writable == true
    end

    test "subjects_per_access_control_entry defaults to 4" do
      defs = AccessControl.attribute_defs()
      attr = Enum.find(defs, &(&1.name == :subjects_per_access_control_entry))
      assert attr.default == 4
    end
  end

  # ── AccessControl GenServer ──────────────────────────────────

  describe "AccessControl GenServer" do
    setup do
      name = :"acl_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = AccessControl.start_link(name: name)
      %{pid: pid, name: name}
    end

    test "default acl is empty list", %{name: name} do
      assert {:ok, []} = GenServer.call(name, {:read_attribute, :acl})
    end

    test "acl is writable", %{name: name} do
      entry = %{privilege: 5, auth_mode: 2, subjects: [1], targets: nil, fabric_index: 1}
      assert :ok = GenServer.call(name, {:write_attribute, :acl, [entry]})
      assert {:ok, [^entry]} = GenServer.call(name, {:read_attribute, :acl})
    end

    test "subjects_per_access_control_entry is read-only", %{name: name} do
      assert {:error, :unsupported_write} =
               GenServer.call(name, {:write_attribute, :subjects_per_access_control_entry, 8})
    end
  end

  # ── GeneralCommissioning GenServer ─────────────────────────────

  describe "GeneralCommissioning GenServer" do
    setup do
      comm_name = :"comm_agent_gc_#{System.unique_integer([:positive])}"
      {:ok, _} = Commissioning.start_link(name: comm_name)

      name = :"gen_comm_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = GeneralCommissioning.start_link(name: name)
      %{pid: pid, name: name, comm_name: comm_name}
    end

    test "breadcrumb is writable", %{name: name} do
      assert :ok = GenServer.call(name, {:write_attribute, :breadcrumb, 42})
      assert {:ok, 42} = GenServer.call(name, {:read_attribute, :breadcrumb})
    end

    test "arm_fail_safe returns success response", %{name: name} do
      assert {:ok, response} =
               GenServer.call(name, {:invoke_command, :arm_fail_safe, %{expiry_length: 900, breadcrumb: 1}})

      assert response[0] == {:uint, 0}
      assert response[1] == {:string, ""}
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :breadcrumb})
    end

    test "commissioning_complete returns success response", %{name: name} do
      assert {:ok, response} =
               GenServer.call(name, {:invoke_command, :commissioning_complete, %{}})

      assert response[0] == {:uint, 0}
    end
  end

  # ── OperationalCredentials GenServer ───────────────────────────

  describe "OperationalCredentials GenServer" do
    setup do
      comm_name = :"comm_agent_oc_#{System.unique_integer([:positive])}"
      {:ok, _} = Commissioning.start_link(name: comm_name)

      name = :"op_cred_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = OperationalCredentials.start_link(name: name)
      %{pid: pid, name: name, comm_name: comm_name}
    end

    test "csr_request generates keypair and returns NOCSR elements", %{name: name} do
      nonce = :crypto.strong_rand_bytes(32)

      assert {:ok, response} =
               GenServer.call(name, {:invoke_command, :csr_request, %{csr_nonce: nonce}})

      # Response has NOCSR elements (bytes) and attestation signature (bytes)
      assert {:bytes, nocsr_elements} = response[0]
      assert {:bytes, _attestation_sig} = response[1]
      assert is_binary(nocsr_elements)
      assert byte_size(nocsr_elements) > 0
    end

    test "add_trusted_root_cert stores cert", %{name: name} do
      root_cert = :crypto.strong_rand_bytes(200)

      assert {:ok, nil} =
               GenServer.call(name, {:invoke_command, :add_trusted_root_cert, %{root_ca_cert: root_cert}})
    end

    test "full CSR → AddRoot → AddNOC flow", %{name: name} do
      alias Matterlix.CASE.Messages, as: CASEMessages

      # 1. CSRRequest
      nonce = :crypto.strong_rand_bytes(32)
      {:ok, csr_response} = GenServer.call(name, {:invoke_command, :csr_request, %{csr_nonce: nonce}})
      {:bytes, nocsr_elements} = csr_response[0]

      # Decode NOCSR to get the public key
      nocsr_decoded = Matterlix.TLV.decode(nocsr_elements)
      pub_key = nocsr_decoded[1]

      # 2. AddTrustedRootCert
      root_cert = :crypto.strong_rand_bytes(200)
      {:ok, nil} = GenServer.call(name, {:invoke_command, :add_trusted_root_cert, %{root_ca_cert: root_cert}})

      # 3. Build NOC using the public key from CSR
      noc = CASEMessages.encode_noc(42, 1, pub_key)
      ipk = :crypto.strong_rand_bytes(16)

      {:ok, noc_response} = GenServer.call(name, {:invoke_command, :add_noc, %{
        noc_value: noc,
        ipk_value: ipk,
        case_admin_subject: 112233,
        admin_vendor_id: 0xFFF1
      }})

      # StatusCode=Success(0), FabricIndex=1
      assert {:uint, 0} = noc_response[0]
      assert {:uint, 1} = noc_response[1]

      # commissioned_fabrics updated
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :commissioned_fabrics})
    end

    test "add_noc with mismatched key fails", %{name: name} do
      alias Matterlix.CASE.Messages, as: CASEMessages
      alias Matterlix.Crypto.Certificate

      # CSRRequest generates a keypair
      GenServer.call(name, {:invoke_command, :csr_request, %{csr_nonce: <<0::256>>}})

      # Build NOC with a DIFFERENT public key
      {different_pub, _priv} = Certificate.generate_keypair()
      noc = CASEMessages.encode_noc(42, 1, different_pub)

      {:ok, noc_response} = GenServer.call(name, {:invoke_command, :add_noc, %{
        noc_value: noc,
        ipk_value: :crypto.strong_rand_bytes(16),
        case_admin_subject: 112233,
        admin_vendor_id: 0xFFF1
      }})

      # StatusCode=InvalidPublicKey(1)
      assert {:uint, 1} = noc_response[0]
    end

    test "supported_fabrics defaults to 5", %{name: name} do
      assert {:ok, 5} = GenServer.call(name, {:read_attribute, :supported_fabrics})
    end

    test "multiple add_noc assigns sequential fabric_index", %{name: name} do
      alias Matterlix.CASE.Messages, as: CASEMessages
      alias Matterlix.Crypto.Certificate

      # First fabric
      {:ok, _csr_resp} = GenServer.call(name, {:invoke_command, :csr_request, %{csr_nonce: <<0::256>>}})
      stored_keypair = Map.get(:sys.get_state(name), :_keypair)
      {pub1, _priv1} = stored_keypair
      noc1 = CASEMessages.encode_noc(42, 1, pub1)

      {:ok, noc_resp1} = GenServer.call(name, {:invoke_command, :add_noc, %{
        noc_value: noc1, ipk_value: :crypto.strong_rand_bytes(16),
        case_admin_subject: 100, admin_vendor_id: 0xFFF1
      }})

      assert {:uint, 0} = noc_resp1[0]   # Success
      assert {:uint, 1} = noc_resp1[1]   # fabric_index = 1

      # Second fabric
      {:ok, _csr_resp2} = GenServer.call(name, {:invoke_command, :csr_request, %{csr_nonce: <<1::256>>}})
      stored_keypair2 = Map.get(:sys.get_state(name), :_keypair)
      {pub2, _priv2} = stored_keypair2
      noc2 = CASEMessages.encode_noc(99, 2, pub2)

      {:ok, noc_resp2} = GenServer.call(name, {:invoke_command, :add_noc, %{
        noc_value: noc2, ipk_value: :crypto.strong_rand_bytes(16),
        case_admin_subject: 200, admin_vendor_id: 0xFFF2
      }})

      assert {:uint, 0} = noc_resp2[0]   # Success
      assert {:uint, 2} = noc_resp2[1]   # fabric_index = 2

      # commissioned_fabrics should be 2
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :commissioned_fabrics})
    end

    test "remove_fabric removes a fabric by index", %{name: name} do
      alias Matterlix.CASE.Messages, as: CASEMessages

      # Add a fabric first
      {:ok, _} = GenServer.call(name, {:invoke_command, :csr_request, %{csr_nonce: <<0::256>>}})
      {pub, _} = Map.get(:sys.get_state(name), :_keypair)
      noc = CASEMessages.encode_noc(42, 1, pub)
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_noc, %{
        noc_value: noc, ipk_value: :crypto.strong_rand_bytes(16),
        case_admin_subject: 100, admin_vendor_id: 0xFFF1
      }})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :commissioned_fabrics})

      # Remove it
      {:ok, resp} = GenServer.call(name, {:invoke_command, :remove_fabric, %{fabric_index: 1}})
      assert {:uint, 0} = resp[0]
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :commissioned_fabrics})
    end

    test "remove_fabric with invalid index returns error", %{name: name} do
      {:ok, resp} = GenServer.call(name, {:invoke_command, :remove_fabric, %{fabric_index: 99}})
      assert {:uint, 11} = resp[0]
    end

    test "update_fabric_label updates the last fabric's label", %{name: name} do
      alias Matterlix.CASE.Messages, as: CASEMessages

      {:ok, _} = GenServer.call(name, {:invoke_command, :csr_request, %{csr_nonce: <<0::256>>}})
      {pub, _} = Map.get(:sys.get_state(name), :_keypair)
      noc = CASEMessages.encode_noc(42, 1, pub)
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_noc, %{
        noc_value: noc, ipk_value: :crypto.strong_rand_bytes(16),
        case_admin_subject: 100, admin_vendor_id: 0xFFF1
      }})

      {:ok, resp} = GenServer.call(name, {:invoke_command, :update_fabric_label, %{label: "My Home"}})
      assert {:uint, 0} = resp[0]

      {:ok, fabrics} = GenServer.call(name, {:read_attribute, :fabrics})
      assert hd(fabrics).label == "My Home"
    end

    test "update_fabric_label with no fabrics returns error", %{name: name} do
      {:ok, resp} = GenServer.call(name, {:invoke_command, :update_fabric_label, %{label: "Test"}})
      assert {:uint, 11} = resp[0]
    end
  end

  # ── NetworkCommissioning metadata ────────────────────────────

  describe "NetworkCommissioning metadata" do
    test "cluster_id and name" do
      assert NetworkCommissioning.cluster_id() == 0x0031
      assert NetworkCommissioning.cluster_name() == :network_commissioning
    end

    test "attribute_defs" do
      defs = NetworkCommissioning.attribute_defs()
      assert length(defs) == 14

      assert Enum.find(defs, &(&1.name == :max_networks)).default == 1
      assert Enum.find(defs, &(&1.name == :interface_enabled)).default == true
      assert Enum.find(defs, &(&1.name == :interface_enabled)).writable == true
      assert Enum.find(defs, &(&1.name == :feature_map)).default == 0x04
    end

    test "manually declared feature_map not duplicated" do
      defs = NetworkCommissioning.attribute_defs()
      feature_maps = Enum.filter(defs, &(&1.id == 0xFFFC))
      assert length(feature_maps) == 1
      assert hd(feature_maps).default == 0x04
    end

    test "command_defs" do
      defs = NetworkCommissioning.command_defs()
      assert length(defs) == 6
      assert Enum.find(defs, &(&1.name == :scan_networks)).id == 0x00
      assert Enum.find(defs, &(&1.name == :connect_network)).id == 0x08
      assert Enum.find(defs, &(&1.name == :reorder_network)).id == 0x0A
    end
  end

  # ── NetworkCommissioning GenServer ──────────────────────────

  describe "NetworkCommissioning GenServer" do
    setup do
      name = :"net_comm_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = NetworkCommissioning.start_link(name: name)
      %{pid: pid, name: name}
    end

    test "default attribute values", %{name: name} do
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :max_networks})
      assert {:ok, []} = GenServer.call(name, {:read_attribute, :networks})
      assert {:ok, 30} = GenServer.call(name, {:read_attribute, :scan_max_time_seconds})
      assert {:ok, true} = GenServer.call(name, {:read_attribute, :interface_enabled})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :last_networking_status})
      assert {:ok, "ethernet"} = GenServer.call(name, {:read_attribute, :last_network_id})
      assert {:ok, 0x04} = GenServer.call(name, {:read_attribute, :feature_map})
    end

    test "interface_enabled is writable", %{name: name} do
      assert :ok = GenServer.call(name, {:write_attribute, :interface_enabled, false})
      assert {:ok, false} = GenServer.call(name, {:read_attribute, :interface_enabled})
    end

    test "scan_networks returns success", %{name: name} do
      assert {:ok, response} =
               GenServer.call(name, {:invoke_command, :scan_networks, %{}})

      assert response[0] == {:uint, 0}
      assert response[1] == {:string, ""}
    end

    test "connect_network returns success", %{name: name} do
      assert {:ok, response} =
               GenServer.call(name, {:invoke_command, :connect_network,
                 %{network_id: "ethernet", breadcrumb: 0}})

      assert response[0] == {:uint, 0}
      assert response[1] == {:string, ""}
      assert response[2] == :null
    end

    test "remove_network returns success", %{name: name} do
      assert {:ok, response} =
               GenServer.call(name, {:invoke_command, :remove_network,
                 %{network_id: "ethernet", breadcrumb: 0}})

      assert response[0] == {:uint, 0}
    end
  end

  # ── GroupKeyManagement metadata ─────────────────────────────

  describe "GroupKeyManagement metadata" do
    test "cluster_id and name" do
      assert GroupKeyManagement.cluster_id() == 0x003F
      assert GroupKeyManagement.cluster_name() == :group_key_management
    end

    test "attribute_defs" do
      defs = GroupKeyManagement.attribute_defs()
      assert length(defs) == 10

      assert Enum.find(defs, &(&1.name == :group_key_map)).writable == true
      assert Enum.find(defs, &(&1.name == :group_table)).writable == false
      assert Enum.find(defs, &(&1.name == :max_groups_per_fabric)).default == 4
    end
  end

  # ── GroupKeyManagement GenServer ────────────────────────────

  describe "GroupKeyManagement GenServer" do
    setup do
      name = :"gkm_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = GroupKeyManagement.start_link(name: name)
      %{pid: pid, name: name}
    end

    test "default attributes", %{name: name} do
      assert {:ok, []} = GenServer.call(name, {:read_attribute, :group_key_map})
      assert {:ok, []} = GenServer.call(name, {:read_attribute, :group_table})
      assert {:ok, 4} = GenServer.call(name, {:read_attribute, :max_groups_per_fabric})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :feature_map})
    end

    test "group_key_map is writable", %{name: name} do
      entry = %{group_id: 1, group_key_set_id: 0}
      assert :ok = GenServer.call(name, {:write_attribute, :group_key_map, [entry]})
      assert {:ok, [^entry]} = GenServer.call(name, {:read_attribute, :group_key_map})
    end

    test "group_table is read-only", %{name: name} do
      assert {:error, :unsupported_write} =
               GenServer.call(name, {:write_attribute, :group_table, []})
    end

    test "key_set_write stores key set and rebuilds group table", %{name: name} do
      epoch_key = :crypto.strong_rand_bytes(16)

      # Write group_key_map FIRST, then key_set_write rebuilds the table
      entry = %{group_id: 100, group_key_set_id: 1}
      :ok = GenServer.call(name, {:write_attribute, :group_key_map, [entry]})

      # Write a key set (triggers rebuild_group_table which reads the map)
      {:ok, nil} = GenServer.call(name, {:invoke_command, :key_set_write, %{
        group_key_set: %{group_key_set_id: 1, epoch_key0: epoch_key, epoch_start_time0: 0}
      }})

      # group_table should now contain the mapping
      {:ok, table} = GenServer.call(name, {:read_attribute, :group_table})
      assert length(table) == 1
      assert hd(table).group_id == 100
      assert hd(table).group_key_set_id == 1
    end

    test "key_set_read returns stored key set", %{name: name} do
      epoch_key = :crypto.strong_rand_bytes(16)

      {:ok, nil} = GenServer.call(name, {:invoke_command, :key_set_write, %{
        group_key_set: %{group_key_set_id: 42, epoch_key0: epoch_key, epoch_start_time0: 1000}
      }})

      {:ok, response} = GenServer.call(name, {:invoke_command, :key_set_read, %{group_key_set_id: 42}})
      {:struct, key_set} = response[0]
      assert key_set[0] == {:uint, 42}
      assert key_set[2] == {:uint, 1000}
    end

    test "key_set_remove deletes key set", %{name: name} do
      epoch_key = :crypto.strong_rand_bytes(16)

      {:ok, nil} = GenServer.call(name, {:invoke_command, :key_set_write, %{
        group_key_set: %{group_key_set_id: 5, epoch_key0: epoch_key}
      }})

      {:ok, nil} = GenServer.call(name, {:invoke_command, :key_set_remove, %{group_key_set_id: 5}})

      # Reading removed key set returns empty struct with just the ID
      {:ok, response} = GenServer.call(name, {:invoke_command, :key_set_read, %{group_key_set_id: 5}})
      {:struct, key_set} = response[0]
      assert key_set[0] == {:uint, 5}
      refute Map.has_key?(key_set, 2)
    end

    test "key_set_read_all_indices lists all key set IDs", %{name: name} do
      for id <- [1, 2, 3] do
        {:ok, nil} = GenServer.call(name, {:invoke_command, :key_set_write, %{
          group_key_set: %{group_key_set_id: id, epoch_key0: :crypto.strong_rand_bytes(16)}
        }})
      end

      {:ok, response} = GenServer.call(name, {:invoke_command, :key_set_read_all_indices, %{}})
      {:list, indices_list} = response[0]
      indices = Enum.map(indices_list, fn {:uint, id} -> id end)
      assert Enum.sort(indices) == [1, 2, 3]
    end

    test "get_group_keys derives operational keys", %{name: name} do
      epoch_key = :crypto.strong_rand_bytes(16)

      # Write map first, then key_set_write rebuilds
      :ok = GenServer.call(name, {:write_attribute, :group_key_map, [
        %{group_id: 100, group_key_set_id: 1}
      ]})

      {:ok, nil} = GenServer.call(name, {:invoke_command, :key_set_write, %{
        group_key_set: %{group_key_set_id: 1, epoch_key0: epoch_key}
      }})

      keys = GenServer.call(name, :get_group_keys)
      assert length(keys) == 1
      [key] = keys
      assert key.group_id == 100
      assert is_integer(key.session_id)
      assert byte_size(key.encrypt_key) == 16
    end
  end

  # ── Identify Cluster ─────────────────────────────────────────

  describe "Identify metadata" do
    test "cluster_id and name" do
      assert Identify.cluster_id() == 0x0003
      assert Identify.cluster_name() == :identify
    end

    test "attribute_defs include identify_time and identify_type" do
      defs = Identify.attribute_defs()
      names = Enum.map(defs, & &1.name)
      assert :identify_time in names
      assert :identify_type in names
      assert :cluster_revision in names

      id_time = Enum.find(defs, &(&1.name == :identify_time))
      assert id_time.writable == true
      assert id_time.default == 0
    end

    test "command_defs include identify and trigger_effect" do
      cmds = Identify.command_defs()
      names = Enum.map(cmds, & &1.name)
      assert :identify in names
      assert :trigger_effect in names
    end
  end

  describe "Identify GenServer" do
    setup do
      name = :"identify_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Identify.start_link(name: name)
      %{name: name}
    end

    test "identify command sets identify_time", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :identify, %{identify_time: 30}})
      assert {:ok, 30} = GenServer.call(name, {:read_attribute, :identify_time})
    end

    test "trigger_effect returns success", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :trigger_effect, %{
        effect_identifier: 0, effect_variant: 0
      }})
    end

    test "identify_time defaults to 0", %{name: name} do
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :identify_time})
    end
  end

  # ── Binding Cluster ─────────────────────────────────────────

  describe "Binding metadata" do
    test "cluster_id and name" do
      assert Binding.cluster_id() == 0x001E
      assert Binding.cluster_name() == :binding
    end

    test "binding attribute is writable list" do
      defs = Binding.attribute_defs()
      binding_attr = Enum.find(defs, &(&1.name == :binding))
      assert binding_attr.writable == true
      assert binding_attr.default == []
    end
  end

  describe "Binding GenServer" do
    setup do
      name = :"binding_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Binding.start_link(name: name)
      %{name: name}
    end

    test "write and read binding entries", %{name: name} do
      entries = [
        %{node: 1, endpoint: 1, cluster: 6},
        %{group: 100}
      ]

      :ok = GenServer.call(name, {:write_attribute, :binding, entries})
      assert {:ok, ^entries} = GenServer.call(name, {:read_attribute, :binding})
    end
  end

  # ── PowerSource Cluster ─────────────────────────────────────

  describe "PowerSource metadata" do
    test "cluster_id and name" do
      assert PowerSource.cluster_id() == 0x002F
      assert PowerSource.cluster_name() == :power_source
    end

    test "attribute_defs include status and bat_percent_remaining" do
      defs = PowerSource.attribute_defs()
      names = Enum.map(defs, & &1.name)
      assert :status in names
      assert :bat_percent_remaining in names
      assert :bat_charge_level in names
    end
  end

  describe "PowerSource GenServer" do
    setup do
      name = :"power_source_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = PowerSource.start_link(name: name)
      %{name: name}
    end

    test "default values", %{name: name} do
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :status})
      assert {:ok, 200} = GenServer.call(name, {:read_attribute, :bat_percent_remaining})
      assert {:ok, "DC Power"} = GenServer.call(name, {:read_attribute, :description})
    end
  end

  # ── Attribute Constraints ───────────────────────────────────

  describe "attribute constraints" do
    test "LevelControl current_level rejects out-of-range values" do
      name = :"level_constraint_#{System.unique_integer([:positive])}"
      {:ok, _pid} = LevelControl.start_link(name: name)

      # Valid write
      assert :ok = GenServer.call(name, {:write_attribute, :current_level, 100})
      assert {:ok, 100} = GenServer.call(name, {:read_attribute, :current_level})

      # Over max (254)
      assert {:error, :constraint_error} = GenServer.call(name, {:write_attribute, :current_level, 255})

      # Under min (0 is valid for current_level)
      assert :ok = GenServer.call(name, {:write_attribute, :current_level, 0})
    end

    test "Thermostat heating setpoint rejects out-of-range values" do
      name = :"therm_constraint_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Thermostat.start_link(name: name)

      # Valid
      assert :ok = GenServer.call(name, {:write_attribute, :occupied_heating_setpoint, 2500})

      # Below min (700)
      assert {:error, :constraint_error} = GenServer.call(name, {:write_attribute, :occupied_heating_setpoint, 500})

      # Above max (3000)
      assert {:error, :constraint_error} = GenServer.call(name, {:write_attribute, :occupied_heating_setpoint, 3500})
    end

    test "Thermostat system_mode rejects invalid enum values" do
      name = :"therm_enum_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Thermostat.start_link(name: name)

      # Valid modes: 0=off, 1=auto, 3=cool, 4=heat, 5=emergency_heat, 7=fan_only
      assert :ok = GenServer.call(name, {:write_attribute, :system_mode, 0})
      assert :ok = GenServer.call(name, {:write_attribute, :system_mode, 4})

      # Invalid mode (2 is not defined)
      assert {:error, :constraint_error} = GenServer.call(name, {:write_attribute, :system_mode, 2})

      # Invalid mode (6 is not defined)
      assert {:error, :constraint_error} = GenServer.call(name, {:write_attribute, :system_mode, 6})
    end

    test "attributes without constraints accept any value" do
      name = :"onoff_no_constraint_#{System.unique_integer([:positive])}"
      {:ok, _pid} = OnOff.start_link(name: name)

      # OnOff has no constraints — boolean values pass
      assert :ok = GenServer.call(name, {:write_attribute, :on_off, true})
      assert :ok = GenServer.call(name, {:write_attribute, :on_off, false})
    end

    test "constraint metadata is stored in attr_def" do
      defs = LevelControl.attribute_defs()
      level = Enum.find(defs, &(&1.name == :current_level))
      assert level.min == 0
      assert level.max == 254

      defs = Thermostat.attribute_defs()
      mode = Enum.find(defs, &(&1.name == :system_mode))
      assert mode.enum_values == [0, 1, 3, 4, 5, 7]
    end
  end

  # ── Scenes Cluster ──────────────────────────────────────────

  describe "Scenes cluster" do
    setup do
      name = :"scenes_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Scenes.start_link(name: name)
      %{name: name}
    end

    test "metadata" do
      assert Scenes.cluster_id() == 0x0005
      assert Scenes.cluster_name() == :scenes
    end

    test "add_scene and view_scene", %{name: name} do
      {:ok, resp} = GenServer.call(name, {:invoke_command, :add_scene, %{
        group_id: 1, scene_id: 10, transition_time: 100, scene_name: "Morning"
      }})

      assert resp[0] == {:uint, 0}
      assert resp[1] == {:uint, 1}
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :scene_count})

      {:ok, view} = GenServer.call(name, {:invoke_command, :view_scene, %{group_id: 1, scene_id: 10}})
      assert view[0] == {:uint, 0}
      assert view[4] == {:string, "Morning"}
    end

    test "remove_scene", %{name: name} do
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_scene, %{group_id: 1, scene_id: 1}})
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_scene, %{group_id: 1, scene_id: 2}})

      {:ok, resp} = GenServer.call(name, {:invoke_command, :remove_scene, %{group_id: 1, scene_id: 1}})
      assert resp[0] == {:uint, 0}
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :scene_count})
    end

    test "remove_all_scenes for a group", %{name: name} do
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_scene, %{group_id: 1, scene_id: 1}})
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_scene, %{group_id: 1, scene_id: 2}})
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_scene, %{group_id: 2, scene_id: 1}})

      {:ok, _} = GenServer.call(name, {:invoke_command, :remove_all_scenes, %{group_id: 1}})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :scene_count})
    end

    test "recall_scene sets current_scene", %{name: name} do
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_scene, %{group_id: 1, scene_id: 5}})
      {:ok, nil} = GenServer.call(name, {:invoke_command, :recall_scene, %{group_id: 1, scene_id: 5}})

      assert {:ok, 5} = GenServer.call(name, {:read_attribute, :current_scene})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :current_group})
      assert {:ok, true} = GenServer.call(name, {:read_attribute, :scene_valid})
    end

    test "get_scene_membership", %{name: name} do
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_scene, %{group_id: 1, scene_id: 1}})
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_scene, %{group_id: 1, scene_id: 2}})

      {:ok, resp} = GenServer.call(name, {:invoke_command, :get_scene_membership, %{group_id: 1}})
      {:list, ids} = resp[3]
      assert length(ids) == 2
    end
  end

  # ── Groups Cluster ──────────────────────────────────────────

  describe "Groups cluster" do
    setup do
      name = :"groups_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Groups.start_link(name: name)
      %{name: name}
    end

    test "metadata" do
      assert Groups.cluster_id() == 0x0004
      assert Groups.cluster_name() == :groups
    end

    test "add_group and view_group", %{name: name} do
      {:ok, resp} = GenServer.call(name, {:invoke_command, :add_group, %{group_id: 100, group_name: "Living Room"}})
      assert resp[0] == {:uint, 0}

      {:ok, view} = GenServer.call(name, {:invoke_command, :view_group, %{group_id: 100}})
      assert view[0] == {:uint, 0}
      assert view[2] == {:string, "Living Room"}
    end

    test "view_group returns not_found for unknown group", %{name: name} do
      {:ok, resp} = GenServer.call(name, {:invoke_command, :view_group, %{group_id: 999}})
      assert resp[0] == {:uint, 0x8B}
    end

    test "remove_group", %{name: name} do
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_group, %{group_id: 1, group_name: "G1"}})
      {:ok, resp} = GenServer.call(name, {:invoke_command, :remove_group, %{group_id: 1}})
      assert resp[0] == {:uint, 0}

      {:ok, view} = GenServer.call(name, {:invoke_command, :view_group, %{group_id: 1}})
      assert view[0] == {:uint, 0x8B}
    end

    test "remove_all_groups", %{name: name} do
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_group, %{group_id: 1, group_name: "G1"}})
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_group, %{group_id: 2, group_name: "G2"}})

      {:ok, nil} = GenServer.call(name, {:invoke_command, :remove_all_groups, %{}})

      {:ok, view} = GenServer.call(name, {:invoke_command, :view_group, %{group_id: 1}})
      assert view[0] == {:uint, 0x8B}
    end

    test "get_group_membership with empty list returns all", %{name: name} do
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_group, %{group_id: 1, group_name: "G1"}})
      {:ok, _} = GenServer.call(name, {:invoke_command, :add_group, %{group_id: 2, group_name: "G2"}})

      {:ok, resp} = GenServer.call(name, {:invoke_command, :get_group_membership, %{group_list: []}})
      {:list, members} = resp[1]
      assert length(members) == 2
    end
  end

  # ── Door Lock Cluster ────────────────────────────────────────

  describe "DoorLock metadata" do
    test "cluster_id and name" do
      assert DoorLock.cluster_id() == 0x0101
      assert DoorLock.cluster_name() == :door_lock
    end

    test "attribute_defs" do
      defs = DoorLock.attribute_defs()
      names = Enum.map(defs, & &1.name)
      assert :lock_state in names
      assert :lock_type in names
      assert :actuator_enabled in names
      assert :operating_mode in names
    end

    test "command_defs" do
      cmds = DoorLock.command_defs()
      names = Enum.map(cmds, & &1.name)
      assert :lock_door in names
      assert :unlock_door in names
      assert :unlock_with_timeout in names
    end
  end

  describe "DoorLock GenServer" do
    setup do
      name = :"door_lock_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = DoorLock.start_link(name: name)
      %{name: name}
    end

    test "default lock_state is unlocked (2)", %{name: name} do
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :lock_state})
    end

    test "lock_door sets lock_state to locked (1)", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :lock_door, %{}})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :lock_state})
    end

    test "unlock_door sets lock_state to unlocked (2)", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :lock_door, %{}})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :lock_state})

      {:ok, nil} = GenServer.call(name, {:invoke_command, :unlock_door, %{}})
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :lock_state})
    end

    test "unlock_with_timeout sets lock_state to unlocked", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :lock_door, %{}})
      {:ok, nil} = GenServer.call(name, {:invoke_command, :unlock_with_timeout, %{timeout: 30}})
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :lock_state})
    end

    test "operating_mode is writable with enum constraint", %{name: name} do
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :operating_mode})
      assert :ok = GenServer.call(name, {:write_attribute, :operating_mode, 2})
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :operating_mode})
    end
  end

  # ── Window Covering Cluster ──────────────────────────────────

  describe "WindowCovering metadata" do
    test "cluster_id and name" do
      assert WindowCovering.cluster_id() == 0x0102
      assert WindowCovering.cluster_name() == :window_covering
    end

    test "attribute_defs" do
      defs = WindowCovering.attribute_defs()
      names = Enum.map(defs, & &1.name)
      assert :type in names
      assert :current_position_lift_percent_100ths in names
      assert :current_position_tilt_percent_100ths in names
      assert :operational_status in names
    end

    test "command_defs" do
      cmds = WindowCovering.command_defs()
      names = Enum.map(cmds, & &1.name)
      assert :up_or_open in names
      assert :down_or_close in names
      assert :stop_motion in names
      assert :go_to_lift_percentage in names
      assert :go_to_tilt_percentage in names
    end
  end

  describe "WindowCovering GenServer" do
    setup do
      name = :"wc_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = WindowCovering.start_link(name: name)
      %{name: name}
    end

    test "default position is 0 (fully open)", %{name: name} do
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :current_position_lift_percent_100ths})
    end

    test "up_or_open sets position to 0", %{name: name} do
      # First close
      {:ok, nil} = GenServer.call(name, {:invoke_command, :down_or_close, %{}})
      assert {:ok, 10000} = GenServer.call(name, {:read_attribute, :current_position_lift_percent_100ths})

      # Then open
      {:ok, nil} = GenServer.call(name, {:invoke_command, :up_or_open, %{}})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :current_position_lift_percent_100ths})
    end

    test "down_or_close sets position to 10000", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :down_or_close, %{}})
      assert {:ok, 10000} = GenServer.call(name, {:read_attribute, :current_position_lift_percent_100ths})
    end

    test "go_to_lift_percentage sets exact position", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :go_to_lift_percentage, %{lift_percent_100ths: 5000}})
      assert {:ok, 5000} = GenServer.call(name, {:read_attribute, :current_position_lift_percent_100ths})
    end

    test "go_to_lift_percentage clamps to valid range", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :go_to_lift_percentage, %{lift_percent_100ths: 99999}})
      assert {:ok, 10000} = GenServer.call(name, {:read_attribute, :current_position_lift_percent_100ths})
    end

    test "go_to_tilt_percentage sets tilt position", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :go_to_tilt_percentage, %{tilt_percent_100ths: 7500}})
      assert {:ok, 7500} = GenServer.call(name, {:read_attribute, :current_position_tilt_percent_100ths})
    end

    test "stop_motion returns success", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :stop_motion, %{}})
    end
  end

  # ── Fan Control Cluster ──────────────────────────────────────

  describe "FanControl metadata" do
    test "cluster_id and name" do
      assert FanControl.cluster_id() == 0x0202
      assert FanControl.cluster_name() == :fan_control
    end

    test "attribute_defs" do
      defs = FanControl.attribute_defs()
      names = Enum.map(defs, & &1.name)
      assert :fan_mode in names
      assert :percent_setting in names
      assert :percent_current in names

      mode = Enum.find(defs, &(&1.name == :fan_mode))
      assert mode.enum_values == [0, 1, 2, 3, 4, 5, 6]
    end
  end

  describe "FanControl GenServer" do
    setup do
      name = :"fan_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = FanControl.start_link(name: name)
      %{name: name}
    end

    test "default values", %{name: name} do
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :fan_mode})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :percent_setting})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :percent_current})
    end

    test "fan_mode is writable with enum constraint", %{name: name} do
      assert :ok = GenServer.call(name, {:write_attribute, :fan_mode, 5})
      assert {:ok, 5} = GenServer.call(name, {:read_attribute, :fan_mode})

      # Invalid mode
      assert {:error, :constraint_error} = GenServer.call(name, {:write_attribute, :fan_mode, 7})
    end

    test "percent_setting is writable with range constraint", %{name: name} do
      assert :ok = GenServer.call(name, {:write_attribute, :percent_setting, 50})
      assert {:ok, 50} = GenServer.call(name, {:read_attribute, :percent_setting})

      # Over max (100)
      assert {:error, :constraint_error} = GenServer.call(name, {:write_attribute, :percent_setting, 101})
    end

    test "step command increases speed", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :step, %{direction: 0}})
      assert {:ok, 10} = GenServer.call(name, {:read_attribute, :percent_setting})
      assert {:ok, 10} = GenServer.call(name, {:read_attribute, :percent_current})
    end

    test "step command decreases speed", %{name: name} do
      :ok = GenServer.call(name, {:write_attribute, :percent_setting, 50})
      {:ok, nil} = GenServer.call(name, {:invoke_command, :step, %{direction: 1}})
      assert {:ok, 40} = GenServer.call(name, {:read_attribute, :percent_setting})
    end

    test "step does not go below 0", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :step, %{direction: 1}})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :percent_setting})
    end

    test "step does not go above 100", %{name: name} do
      :ok = GenServer.call(name, {:write_attribute, :percent_setting, 95})
      {:ok, nil} = GenServer.call(name, {:invoke_command, :step, %{direction: 0}})
      assert {:ok, 100} = GenServer.call(name, {:read_attribute, :percent_setting})
    end
  end

  # ── Occupancy Sensing Cluster ────────────────────────────────

  describe "OccupancySensing metadata" do
    test "cluster_id and name" do
      assert OccupancySensing.cluster_id() == 0x0406
      assert OccupancySensing.cluster_name() == :occupancy_sensing
    end

    test "attribute_defs" do
      defs = OccupancySensing.attribute_defs()
      names = Enum.map(defs, & &1.name)
      assert :occupancy in names
      assert :occupancy_sensor_type in names
      assert :occupancy_sensor_type_bitmap in names
    end
  end

  describe "OccupancySensing GenServer" do
    setup do
      name = :"occ_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = OccupancySensing.start_link(name: name)
      %{name: name}
    end

    test "default values", %{name: name} do
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :occupancy})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :occupancy_sensor_type})
      assert {:ok, 0x01} = GenServer.call(name, {:read_attribute, :occupancy_sensor_type_bitmap})
    end
  end

  # ── Illuminance Measurement Cluster ──────────────────────────

  describe "IlluminanceMeasurement metadata" do
    test "cluster_id and name" do
      assert IlluminanceMeasurement.cluster_id() == 0x0400
      assert IlluminanceMeasurement.cluster_name() == :illuminance_measurement
    end

    test "attribute_defs" do
      defs = IlluminanceMeasurement.attribute_defs()
      names = Enum.map(defs, & &1.name)
      assert :measured_value in names
      assert :min_measured_value in names
      assert :max_measured_value in names
      assert :light_sensor_type in names
    end
  end

  describe "IlluminanceMeasurement GenServer" do
    setup do
      name = :"illum_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = IlluminanceMeasurement.start_link(name: name)
      %{name: name}
    end

    test "default values", %{name: name} do
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :measured_value})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :min_measured_value})
      assert {:ok, 0xFFFE} = GenServer.call(name, {:read_attribute, :max_measured_value})
    end
  end

  # ── Relative Humidity Measurement Cluster ────────────────────

  describe "RelativeHumidityMeasurement metadata" do
    test "cluster_id and name" do
      assert RelativeHumidityMeasurement.cluster_id() == 0x0405
      assert RelativeHumidityMeasurement.cluster_name() == :relative_humidity_measurement
    end

    test "attribute_defs" do
      defs = RelativeHumidityMeasurement.attribute_defs()
      names = Enum.map(defs, & &1.name)
      assert :measured_value in names
      assert :min_measured_value in names
      assert :max_measured_value in names
      assert :tolerance in names
    end
  end

  describe "RelativeHumidityMeasurement GenServer" do
    setup do
      name = :"rh_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = RelativeHumidityMeasurement.start_link(name: name)
      %{name: name}
    end

    test "default values", %{name: name} do
      assert {:ok, 5000} = GenServer.call(name, {:read_attribute, :measured_value})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :min_measured_value})
      assert {:ok, 10000} = GenServer.call(name, {:read_attribute, :max_measured_value})
    end
  end

  # ── Pressure Measurement Cluster ─────────────────────────────

  describe "PressureMeasurement" do
    test "metadata" do
      assert PressureMeasurement.cluster_id() == 0x0403
      assert PressureMeasurement.cluster_name() == :pressure_measurement
    end

    test "attribute_defs" do
      defs = PressureMeasurement.attribute_defs()
      names = Enum.map(defs, & &1.name)
      assert :measured_value in names
      assert :min_measured_value in names
      assert :max_measured_value in names
      assert :tolerance in names
    end

    test "default values" do
      name = :"pressure_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = PressureMeasurement.start_link(name: name)

      assert {:ok, 1013} = GenServer.call(name, {:read_attribute, :measured_value})
      assert {:ok, 300} = GenServer.call(name, {:read_attribute, :min_measured_value})
      assert {:ok, 1100} = GenServer.call(name, {:read_attribute, :max_measured_value})
    end
  end

  # ── Flow Measurement Cluster ─────────────────────────────────

  describe "FlowMeasurement" do
    test "metadata" do
      assert FlowMeasurement.cluster_id() == 0x0404
      assert FlowMeasurement.cluster_name() == :flow_measurement
    end

    test "default values" do
      name = :"flow_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = FlowMeasurement.start_link(name: name)

      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :measured_value})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :min_measured_value})
      assert {:ok, 0xFFFE} = GenServer.call(name, {:read_attribute, :max_measured_value})
    end
  end

  # ── Pump Configuration and Control Cluster ───────────────────

  describe "PumpConfigurationAndControl" do
    test "metadata" do
      assert PumpConfigurationAndControl.cluster_id() == 0x0200
      assert PumpConfigurationAndControl.cluster_name() == :pump_configuration_and_control
    end

    test "attribute_defs" do
      defs = PumpConfigurationAndControl.attribute_defs()
      names = Enum.map(defs, & &1.name)
      assert :max_pressure in names
      assert :max_speed in names
      assert :max_flow in names
      assert :operation_mode in names
      assert :control_mode in names
      assert :effective_operation_mode in names
    end

    test "default values and writable attributes" do
      name = :"pump_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = PumpConfigurationAndControl.start_link(name: name)

      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :operation_mode})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :control_mode})

      # operation_mode is writable with enum constraint
      assert :ok = GenServer.call(name, {:write_attribute, :operation_mode, 2})
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :operation_mode})

      # Invalid mode
      assert {:error, :constraint_error} = GenServer.call(name, {:write_attribute, :operation_mode, 4})
    end
  end

  # ── General Diagnostics Cluster ──────────────────────────────

  describe "GeneralDiagnostics" do
    test "metadata" do
      assert GeneralDiagnostics.cluster_id() == 0x0033
      assert GeneralDiagnostics.cluster_name() == :general_diagnostics
    end

    test "attribute_defs" do
      defs = GeneralDiagnostics.attribute_defs()
      names = Enum.map(defs, & &1.name)
      assert :network_interfaces in names
      assert :reboot_count in names
      assert :up_time in names
      assert :boot_reason in names
      assert :active_hardware_faults in names
      assert :test_event_triggers_enabled in names
    end

    test "default values" do
      name = :"gen_diag_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = GeneralDiagnostics.start_link(name: name)

      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :reboot_count})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :boot_reason})
      assert {:ok, []} = GenServer.call(name, {:read_attribute, :active_hardware_faults})
      assert {:ok, false} = GenServer.call(name, {:read_attribute, :test_event_triggers_enabled})
    end
  end

  # ── Software Diagnostics Cluster ─────────────────────────────

  describe "SoftwareDiagnostics" do
    test "metadata" do
      assert SoftwareDiagnostics.cluster_id() == 0x0034
      assert SoftwareDiagnostics.cluster_name() == :software_diagnostics
    end

    test "default values and reset_watermarks" do
      name = :"sw_diag_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = SoftwareDiagnostics.start_link(name: name)

      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :current_heap_free})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :current_heap_high_watermark})

      {:ok, nil} = GenServer.call(name, {:invoke_command, :reset_watermarks, %{}})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :current_heap_high_watermark})
    end
  end

  # ── WiFi Network Diagnostics Cluster ─────────────────────────

  describe "WiFiNetworkDiagnostics" do
    test "metadata" do
      assert WiFiNetworkDiagnostics.cluster_id() == 0x0036
      assert WiFiNetworkDiagnostics.cluster_name() == :wifi_network_diagnostics
    end

    test "default values" do
      name = :"wifi_diag_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = WiFiNetworkDiagnostics.start_link(name: name)

      assert {:ok, 4} = GenServer.call(name, {:read_attribute, :security_type})
      assert {:ok, -50} = GenServer.call(name, {:read_attribute, :rssi})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :channel_number})
    end

    test "reset_counts zeroes all counters" do
      name = :"wifi_diag_reset_#{System.unique_integer([:positive])}"
      {:ok, _pid} = WiFiNetworkDiagnostics.start_link(name: name)

      {:ok, nil} = GenServer.call(name, {:invoke_command, :reset_counts, %{}})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :beacon_lost_count})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :beacon_rx_count})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :overrun_count})
    end
  end

  # ── Ethernet Network Diagnostics Cluster ─────────────────────

  describe "EthernetNetworkDiagnostics" do
    test "metadata" do
      assert EthernetNetworkDiagnostics.cluster_id() == 0x0037
      assert EthernetNetworkDiagnostics.cluster_name() == :ethernet_network_diagnostics
    end

    test "default values and reset_counts" do
      name = :"eth_diag_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = EthernetNetworkDiagnostics.start_link(name: name)

      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :phy_rate})
      assert {:ok, true} = GenServer.call(name, {:read_attribute, :full_duplex})
      assert {:ok, true} = GenServer.call(name, {:read_attribute, :carrier_detect})

      {:ok, nil} = GenServer.call(name, {:invoke_command, :reset_counts, %{}})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :packet_rx_count})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :collision_count})
    end
  end

  # ── Admin Commissioning Cluster ──────────────────────────────

  describe "AdminCommissioning" do
    test "metadata" do
      assert AdminCommissioning.cluster_id() == 0x003C
      assert AdminCommissioning.cluster_name() == :admin_commissioning
    end

    test "default window_status is closed (0)" do
      name = :"admin_comm_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = AdminCommissioning.start_link(name: name)

      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :window_status})
    end

    test "open_commissioning_window sets enhanced mode" do
      name = :"admin_comm_open_#{System.unique_integer([:positive])}"
      {:ok, _pid} = AdminCommissioning.start_link(name: name)

      {:ok, nil} = GenServer.call(name, {:invoke_command, :open_commissioning_window, %{
        commissioning_timeout: 300,
        pake_passcode_verifier: <<0::256>>,
        discriminator: 3840,
        iterations: 1000,
        salt: :crypto.strong_rand_bytes(32)
      }})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :window_status})
    end

    test "open_basic_commissioning_window sets basic mode" do
      name = :"admin_comm_basic_#{System.unique_integer([:positive])}"
      {:ok, _pid} = AdminCommissioning.start_link(name: name)

      {:ok, nil} = GenServer.call(name, {:invoke_command, :open_basic_commissioning_window, %{
        commissioning_timeout: 180
      }})
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :window_status})
    end

    test "revoke_commissioning closes the window" do
      name = :"admin_comm_revoke_#{System.unique_integer([:positive])}"
      {:ok, _pid} = AdminCommissioning.start_link(name: name)

      {:ok, nil} = GenServer.call(name, {:invoke_command, :open_basic_commissioning_window, %{
        commissioning_timeout: 180
      }})
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :window_status})

      {:ok, nil} = GenServer.call(name, {:invoke_command, :revoke_commissioning, %{}})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :window_status})
    end
  end

  # ── Localization Configuration Cluster ───────────────────────

  describe "LocalizationConfiguration" do
    test "metadata" do
      assert LocalizationConfiguration.cluster_id() == 0x002B
      assert LocalizationConfiguration.cluster_name() == :localization_configuration
    end

    test "default values and writable locale" do
      name = :"locale_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = LocalizationConfiguration.start_link(name: name)

      assert {:ok, "en-US"} = GenServer.call(name, {:read_attribute, :active_locale})
      assert {:ok, ["en-US"]} = GenServer.call(name, {:read_attribute, :supported_locales})

      assert :ok = GenServer.call(name, {:write_attribute, :active_locale, "nl-NL"})
      assert {:ok, "nl-NL"} = GenServer.call(name, {:read_attribute, :active_locale})
    end
  end

  # ── Time Format Localization Cluster ─────────────────────────

  describe "TimeFormatLocalization" do
    test "metadata" do
      assert TimeFormatLocalization.cluster_id() == 0x002C
      assert TimeFormatLocalization.cluster_name() == :time_format_localization
    end

    test "hour_format is writable with enum constraint" do
      name = :"time_fmt_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = TimeFormatLocalization.start_link(name: name)

      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :hour_format})
      assert :ok = GenServer.call(name, {:write_attribute, :hour_format, 0})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :hour_format})

      assert {:error, :constraint_error} = GenServer.call(name, {:write_attribute, :hour_format, 2})
    end
  end

  # ── Unit Localization Cluster ────────────────────────────────

  describe "UnitLocalization" do
    test "metadata" do
      assert UnitLocalization.cluster_id() == 0x002D
      assert UnitLocalization.cluster_name() == :unit_localization
    end

    test "temperature_unit is writable with enum constraint" do
      name = :"unit_loc_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = UnitLocalization.start_link(name: name)

      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :temperature_unit})
      assert :ok = GenServer.call(name, {:write_attribute, :temperature_unit, 0})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :temperature_unit})

      assert {:error, :constraint_error} = GenServer.call(name, {:write_attribute, :temperature_unit, 3})
    end
  end

  # ── Time Synchronization Cluster ─────────────────────────────

  describe "TimeSynchronization" do
    test "metadata" do
      assert TimeSynchronization.cluster_id() == 0x0038
      assert TimeSynchronization.cluster_name() == :time_synchronization
    end

    test "default values" do
      name = :"time_sync_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = TimeSynchronization.start_link(name: name)

      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :utc_time})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :granularity})
    end

    test "set_utc_time updates time attributes" do
      name = :"time_sync_set_#{System.unique_integer([:positive])}"
      {:ok, _pid} = TimeSynchronization.start_link(name: name)

      {:ok, nil} = GenServer.call(name, {:invoke_command, :set_utc_time, %{
        utc_time: 1_700_000_000_000_000,
        granularity: 4,
        time_source: 2
      }})

      assert {:ok, 1_700_000_000_000_000} = GenServer.call(name, {:read_attribute, :utc_time})
      assert {:ok, 4} = GenServer.call(name, {:read_attribute, :granularity})
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :time_source})
    end
  end

  # ── Switch Cluster ───────────────────────────────────────────

  describe "Switch" do
    test "metadata" do
      assert Switch.cluster_id() == 0x003B
      assert Switch.cluster_name() == :switch
    end

    test "default values" do
      name = :"switch_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Switch.start_link(name: name)

      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :number_of_positions})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :current_position})
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :multi_press_max})
    end
  end

  # ── Mode Select Cluster ─────────────────────────────────────

  describe "ModeSelect" do
    setup do
      name = :"mode_select_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = ModeSelect.start_link(name: name)
      %{name: name}
    end

    test "metadata" do
      assert ModeSelect.cluster_id() == 0x0050
      assert ModeSelect.cluster_name() == :mode_select
    end

    test "default values", %{name: name} do
      assert {:ok, "Mode"} = GenServer.call(name, {:read_attribute, :description})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :current_mode})

      {:ok, modes} = GenServer.call(name, {:read_attribute, :supported_modes})
      assert length(modes) == 3
    end

    test "change_to_mode with valid mode", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :change_to_mode, %{new_mode: 1}})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :current_mode})
    end

    test "change_to_mode with invalid mode returns error", %{name: name} do
      assert {:error, :constraint_error} =
               GenServer.call(name, {:invoke_command, :change_to_mode, %{new_mode: 99}})
    end
  end

  # ── Fixed Label Cluster ──────────────────────────────────────

  describe "FixedLabel" do
    test "metadata" do
      assert FixedLabel.cluster_id() == 0x0040
      assert FixedLabel.cluster_name() == :fixed_label
    end

    test "default values" do
      name = :"fixed_label_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = FixedLabel.start_link(name: name)

      assert {:ok, []} = GenServer.call(name, {:read_attribute, :label_list})
    end

    test "label_list is not writable" do
      name = :"fixed_label_rw_#{System.unique_integer([:positive])}"
      {:ok, _pid} = FixedLabel.start_link(name: name)

      assert {:error, :unsupported_write} =
               GenServer.call(name, {:write_attribute, :label_list, [%{label: "room", value: "kitchen"}]})
    end
  end

  # ── User Label Cluster ───────────────────────────────────────

  describe "UserLabel" do
    test "metadata" do
      assert UserLabel.cluster_id() == 0x0041
      assert UserLabel.cluster_name() == :user_label
    end

    test "label_list is writable" do
      name = :"user_label_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = UserLabel.start_link(name: name)

      labels = [%{label: "room", value: "kitchen"}, %{label: "floor", value: "1"}]
      assert :ok = GenServer.call(name, {:write_attribute, :label_list, labels})
      assert {:ok, ^labels} = GenServer.call(name, {:read_attribute, :label_list})
    end
  end

  # ── OTA Software Update Provider Cluster ─────────────────────

  describe "OTASoftwareUpdateProvider" do
    test "metadata" do
      assert OTASoftwareUpdateProvider.cluster_id() == 0x0029
      assert OTASoftwareUpdateProvider.cluster_name() == :ota_software_update_provider
    end

    test "query_image returns not available" do
      name = :"ota_prov_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = OTASoftwareUpdateProvider.start_link(name: name)

      {:ok, resp} = GenServer.call(name, {:invoke_command, :query_image, %{
        vendor_id: 0xFFF1,
        product_id: 0x8001,
        software_version: 1
      }})
      # Status=NotAvailable(2)
      assert resp[0] == {:uint, 2}
    end

    test "apply_update_request returns proceed" do
      name = :"ota_prov_apply_#{System.unique_integer([:positive])}"
      {:ok, _pid} = OTASoftwareUpdateProvider.start_link(name: name)

      {:ok, resp} = GenServer.call(name, {:invoke_command, :apply_update_request, %{
        update_token: :crypto.strong_rand_bytes(32),
        new_version: 2
      }})
      assert resp[0] == {:uint, 0}
    end

    test "notify_update_applied returns success" do
      name = :"ota_prov_notify_#{System.unique_integer([:positive])}"
      {:ok, _pid} = OTASoftwareUpdateProvider.start_link(name: name)

      {:ok, nil} = GenServer.call(name, {:invoke_command, :notify_update_applied, %{
        update_token: :crypto.strong_rand_bytes(32),
        software_version: 2
      }})
    end
  end

  # ── OTA Software Update Requestor Cluster ────────────────────

  describe "OTASoftwareUpdateRequestor" do
    test "metadata" do
      assert OTASoftwareUpdateRequestor.cluster_id() == 0x002A
      assert OTASoftwareUpdateRequestor.cluster_name() == :ota_software_update_requestor
    end

    test "default values" do
      name = :"ota_req_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = OTASoftwareUpdateRequestor.start_link(name: name)

      assert {:ok, []} = GenServer.call(name, {:read_attribute, :default_ota_providers})
      assert {:ok, true} = GenServer.call(name, {:read_attribute, :update_possible})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :update_state})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :update_state_progress})
    end

    test "announce_ota_provider returns success" do
      name = :"ota_req_announce_#{System.unique_integer([:positive])}"
      {:ok, _pid} = OTASoftwareUpdateRequestor.start_link(name: name)

      {:ok, nil} = GenServer.call(name, {:invoke_command, :announce_ota_provider, %{
        provider_node_id: 1,
        vendor_id: 0xFFF1,
        announcement_reason: 0,
        endpoint: 0
      }})
    end

    test "default_ota_providers is writable" do
      name = :"ota_req_write_#{System.unique_integer([:positive])}"
      {:ok, _pid} = OTASoftwareUpdateRequestor.start_link(name: name)

      providers = [%{provider_node_id: 1, endpoint: 0, fabric_index: 1}]
      assert :ok = GenServer.call(name, {:write_attribute, :default_ota_providers, providers})
      assert {:ok, ^providers} = GenServer.call(name, {:read_attribute, :default_ota_providers})
    end
  end

  # ── Electrical Measurement Cluster ───────────────────────────

  describe "ElectricalMeasurement" do
    test "metadata" do
      assert ElectricalMeasurement.cluster_id() == 0x0B04
      assert ElectricalMeasurement.cluster_name() == :electrical_measurement
    end

    test "default values" do
      name = :"elec_meas_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = ElectricalMeasurement.start_link(name: name)

      assert {:ok, 230} = GenServer.call(name, {:read_attribute, :rms_voltage})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :rms_current})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :active_power})
    end
  end

  # ── Power Topology Cluster ──────────────────────────────────

  describe "PowerTopology" do
    test "metadata" do
      assert PowerTopology.cluster_id() == 0x009C
      assert PowerTopology.cluster_name() == :power_topology
    end

    test "default values" do
      name = :"power_topo_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = PowerTopology.start_link(name: name)

      assert {:ok, []} = GenServer.call(name, {:read_attribute, :available_endpoints})
      assert {:ok, []} = GenServer.call(name, {:read_attribute, :active_endpoints})
    end
  end

  # ── Air Quality Cluster ──────────────────────────────────────

  describe "AirQuality" do
    test "metadata" do
      assert AirQuality.cluster_id() == 0x005B
      assert AirQuality.cluster_name() == :air_quality
    end

    test "default value is Unknown (0)" do
      name = :"air_qual_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = AirQuality.start_link(name: name)

      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :air_quality})
    end
  end

  # ── Concentration Measurement Clusters ───────────────────────

  describe "ConcentrationMeasurement clusters" do
    test "PM2.5 metadata" do
      assert PM25ConcentrationMeasurement.cluster_id() == 0x042A
      assert PM25ConcentrationMeasurement.cluster_name() == :pm25_concentration_measurement
    end

    test "CO2 metadata" do
      assert CarbonDioxideConcentrationMeasurement.cluster_id() == 0x040D
      assert CarbonDioxideConcentrationMeasurement.cluster_name() == :carbon_dioxide_concentration_measurement
    end

    test "PM2.5 default values" do
      name = :"pm25_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = PM25ConcentrationMeasurement.start_link(name: name)

      assert {:ok, 0.0} = GenServer.call(name, {:read_attribute, :measured_value})
      assert {:ok, 0.0} = GenServer.call(name, {:read_attribute, :min_measured_value})
      assert {:ok, 1000.0} = GenServer.call(name, {:read_attribute, :max_measured_value})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :measurement_unit})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :measurement_medium})
    end

    test "CO2 default values" do
      name = :"co2_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = CarbonDioxideConcentrationMeasurement.start_link(name: name)

      assert {:ok, 0.0} = GenServer.call(name, {:read_attribute, :measured_value})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :level_indication})
    end
  end

  # ── ICD Management Cluster ───────────────────────────────────

  describe "ICDManagement" do
    setup do
      name = :"icd_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = ICDManagement.start_link(name: name)
      %{name: name}
    end

    test "metadata" do
      assert ICDManagement.cluster_id() == 0x0046
      assert ICDManagement.cluster_name() == :icd_management
    end

    test "default values", %{name: name} do
      assert {:ok, 300} = GenServer.call(name, {:read_attribute, :idle_mode_duration})
      assert {:ok, 300} = GenServer.call(name, {:read_attribute, :active_mode_duration})
      assert {:ok, []} = GenServer.call(name, {:read_attribute, :registered_clients})
      assert {:ok, 0} = GenServer.call(name, {:read_attribute, :operating_mode})
    end

    test "register_client adds client entry", %{name: name} do
      key = :crypto.strong_rand_bytes(16)
      {:ok, resp} = GenServer.call(name, {:invoke_command, :register_client, %{
        check_in_node_id: 42,
        monitored_subject: 100,
        key: key
      }})
      # Returns ICDCounter
      assert resp[0] == {:uint, 0}

      {:ok, clients} = GenServer.call(name, {:read_attribute, :registered_clients})
      assert length(clients) == 1
      assert hd(clients).check_in_node_id == 42
    end

    test "register_client replaces existing entry", %{name: name} do
      key1 = :crypto.strong_rand_bytes(16)
      key2 = :crypto.strong_rand_bytes(16)

      {:ok, _} = GenServer.call(name, {:invoke_command, :register_client, %{
        check_in_node_id: 42, monitored_subject: 100, key: key1
      }})
      {:ok, _} = GenServer.call(name, {:invoke_command, :register_client, %{
        check_in_node_id: 42, monitored_subject: 200, key: key2
      }})

      {:ok, clients} = GenServer.call(name, {:read_attribute, :registered_clients})
      assert length(clients) == 1
      assert hd(clients).monitored_subject == 200
    end

    test "unregister_client removes client", %{name: name} do
      {:ok, _} = GenServer.call(name, {:invoke_command, :register_client, %{
        check_in_node_id: 42, monitored_subject: 100, key: :crypto.strong_rand_bytes(16)
      }})

      {:ok, nil} = GenServer.call(name, {:invoke_command, :unregister_client, %{
        check_in_node_id: 42
      }})

      {:ok, clients} = GenServer.call(name, {:read_attribute, :registered_clients})
      assert clients == []
    end

    test "stay_active_request returns promised duration", %{name: name} do
      {:ok, resp} = GenServer.call(name, {:invoke_command, :stay_active_request, %{
        stay_active_duration: 10_000
      }})
      assert resp[0] == {:uint, 10_000}
    end

    test "stay_active_request caps at 30 seconds", %{name: name} do
      {:ok, resp} = GenServer.call(name, {:invoke_command, :stay_active_request, %{
        stay_active_duration: 60_000
      }})
      assert resp[0] == {:uint, 30_000}
    end
  end

  # ── Device Energy Management Cluster ─────────────────────────

  describe "DeviceEnergyManagement" do
    setup do
      name = :"dem_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = DeviceEnergyManagement.start_link(name: name)
      %{name: name}
    end

    test "metadata" do
      assert DeviceEnergyManagement.cluster_id() == 0x0098
      assert DeviceEnergyManagement.cluster_name() == :device_energy_management
    end

    test "default esa_state is Online (1)", %{name: name} do
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :esa_state})
    end

    test "power_adjust_request sets PowerAdjustActive state", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :power_adjust_request, %{
        power: 5000, duration: 3600, cause: 0
      }})
      assert {:ok, 3} = GenServer.call(name, {:read_attribute, :esa_state})
    end

    test "cancel_power_adjust restores Online state", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :power_adjust_request, %{
        power: 5000, duration: 3600, cause: 0
      }})
      {:ok, nil} = GenServer.call(name, {:invoke_command, :cancel_power_adjust_request, %{}})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :esa_state})
    end

    test "pause and resume", %{name: name} do
      {:ok, nil} = GenServer.call(name, {:invoke_command, :pause_request, %{duration: 300, cause: 0}})
      assert {:ok, 4} = GenServer.call(name, {:read_attribute, :esa_state})

      {:ok, nil} = GenServer.call(name, {:invoke_command, :resume_request, %{}})
      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :esa_state})
    end
  end

  # ── Energy Preference Cluster ────────────────────────────────

  describe "EnergyPreference" do
    test "metadata" do
      assert EnergyPreference.cluster_id() == 0x009B
      assert EnergyPreference.cluster_name() == :energy_preference
    end

    test "default values and writable balance" do
      name = :"energy_pref_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = EnergyPreference.start_link(name: name)

      assert {:ok, 1} = GenServer.call(name, {:read_attribute, :current_energy_balance})
      {:ok, balances} = GenServer.call(name, {:read_attribute, :energy_balances})
      assert length(balances) == 3

      assert :ok = GenServer.call(name, {:write_attribute, :current_energy_balance, 2})
      assert {:ok, 2} = GenServer.call(name, {:read_attribute, :current_energy_balance})
    end
  end
end
