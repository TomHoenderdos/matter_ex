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

  # ── Cluster macro metadata ────────────────────────────────────

  describe "cluster metadata" do
    test "OnOff cluster_id and name" do
      assert OnOff.cluster_id() == 0x0006
      assert OnOff.cluster_name() == :on_off
    end

    test "OnOff attribute_defs" do
      defs = OnOff.attribute_defs()
      assert length(defs) == 2

      on_off_attr = Enum.find(defs, &(&1.name == :on_off))
      assert on_off_attr.id == 0x0000
      assert on_off_attr.type == :boolean
      assert on_off_attr.default == false
      assert on_off_attr.writable == true

      rev_attr = Enum.find(defs, &(&1.name == :cluster_revision))
      assert rev_attr.id == 0xFFFD
      assert rev_attr.writable == false
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
      assert length(defs) == 5

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
      assert length(defs) == 10

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
      assert length(defs) == 5
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
      assert length(defs) == 2
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
      assert length(defs) == 10

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
end
