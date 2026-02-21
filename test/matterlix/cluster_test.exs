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
      assert length(defs) == 3
      assert Enum.find(defs, &(&1.name == :csr_request)).id == 0x04
      assert Enum.find(defs, &(&1.name == :add_noc)).id == 0x06
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
end
