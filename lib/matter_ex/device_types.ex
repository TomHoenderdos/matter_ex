defmodule MatterEx.DeviceTypes do
  @moduledoc """
  Matter Device Type registry.

  Maps device type IDs to their metadata: name, required server clusters,
  and optional server clusters. Used by the Descriptor cluster to populate
  device_type_list and validate cluster requirements.

  Reference: Matter Specification, Chapter 9 (Device Library).
  """

  @type device_type :: %{
          id: non_neg_integer(),
          name: atom(),
          revision: non_neg_integer(),
          required_clusters: [non_neg_integer()],
          optional_clusters: [non_neg_integer()]
        }

  # Cluster IDs used in device type definitions
  @descriptor 0x001D
  @binding 0x001E
  @identify 0x0003
  @groups 0x0004
  @scenes 0x0005
  @on_off 0x0006
  @level_control 0x0008
  @color_control 0x0300
  @thermostat 0x0201
  @fan_control 0x0202
  @door_lock 0x0101
  @window_covering 0x0102
  @pump_config 0x0200
  @temp_measurement 0x0402
  @pressure_measurement 0x0403
  @flow_measurement 0x0404
  @humidity_measurement 0x0405
  @occupancy_sensing 0x0406
  @boolean_state 0x0045
  @power_source 0x002F
  @switch 0x003B
  @mode_select 0x0050
  @media_playback 0x0506
  @content_launcher 0x050A
  @audio_output 0x050B
  @air_quality 0x005B

  @device_types %{
    # Root Node (Endpoint 0)
    0x0016 => %{
      name: :root_node,
      revision: 2,
      required_clusters: [@descriptor, 0x0028, 0x003E, 0x0031, 0x0033, 0x003C, 0x003F],
      optional_clusters: [0x002B, 0x002C, 0x002D, 0x0034, 0x0036, 0x0037, 0x0038]
    },
    # On/Off Light
    0x0100 => %{
      name: :on_off_light,
      revision: 3,
      required_clusters: [@descriptor, @identify, @groups, @scenes, @on_off],
      optional_clusters: [@level_control, @color_control, @occupancy_sensing]
    },
    # Dimmable Light
    0x0101 => %{
      name: :dimmable_light,
      revision: 3,
      required_clusters: [@descriptor, @identify, @groups, @scenes, @on_off, @level_control],
      optional_clusters: [@color_control, @occupancy_sensing]
    },
    # Color Temperature Light
    0x010C => %{
      name: :color_temperature_light,
      revision: 3,
      required_clusters: [@descriptor, @identify, @groups, @scenes, @on_off, @level_control, @color_control],
      optional_clusters: []
    },
    # Extended Color Light
    0x010D => %{
      name: :extended_color_light,
      revision: 3,
      required_clusters: [@descriptor, @identify, @groups, @scenes, @on_off, @level_control, @color_control],
      optional_clusters: []
    },
    # On/Off Plug-in Unit
    0x010A => %{
      name: :on_off_plug_in_unit,
      revision: 3,
      required_clusters: [@descriptor, @identify, @groups, @scenes, @on_off],
      optional_clusters: [@level_control]
    },
    # Dimmable Plug-in Unit
    0x010B => %{
      name: :dimmable_plug_in_unit,
      revision: 3,
      required_clusters: [@descriptor, @identify, @groups, @scenes, @on_off, @level_control],
      optional_clusters: []
    },
    # On/Off Light Switch
    0x0103 => %{
      name: :on_off_light_switch,
      revision: 3,
      required_clusters: [@descriptor, @identify, @binding],
      optional_clusters: []
    },
    # Dimmer Switch
    0x0104 => %{
      name: :dimmer_switch,
      revision: 3,
      required_clusters: [@descriptor, @identify, @binding],
      optional_clusters: []
    },
    # Generic Switch
    0x000F => %{
      name: :generic_switch,
      revision: 2,
      required_clusters: [@descriptor, @identify, @switch],
      optional_clusters: []
    },
    # Contact Sensor
    0x0015 => %{
      name: :contact_sensor,
      revision: 1,
      required_clusters: [@descriptor, @identify, @boolean_state],
      optional_clusters: []
    },
    # Door Lock
    0x000A => %{
      name: :door_lock,
      revision: 3,
      required_clusters: [@descriptor, @identify, @door_lock],
      optional_clusters: [@groups, @scenes]
    },
    # Window Covering
    0x0202 => %{
      name: :window_covering,
      revision: 3,
      required_clusters: [@descriptor, @identify, @groups, @scenes, @window_covering],
      optional_clusters: []
    },
    # Thermostat
    0x0301 => %{
      name: :thermostat,
      revision: 3,
      required_clusters: [@descriptor, @identify, @thermostat],
      optional_clusters: [@groups, @scenes, @fan_control]
    },
    # Fan
    0x002B => %{
      name: :fan,
      revision: 2,
      required_clusters: [@descriptor, @identify, @fan_control],
      optional_clusters: [@groups]
    },
    # Temperature Sensor
    0x0302 => %{
      name: :temperature_sensor,
      revision: 2,
      required_clusters: [@descriptor, @identify, @temp_measurement],
      optional_clusters: []
    },
    # Pressure Sensor
    0x0305 => %{
      name: :pressure_sensor,
      revision: 2,
      required_clusters: [@descriptor, @identify, @pressure_measurement],
      optional_clusters: []
    },
    # Flow Sensor
    0x0306 => %{
      name: :flow_sensor,
      revision: 2,
      required_clusters: [@descriptor, @identify, @flow_measurement],
      optional_clusters: []
    },
    # Humidity Sensor
    0x0307 => %{
      name: :humidity_sensor,
      revision: 2,
      required_clusters: [@descriptor, @identify, @humidity_measurement],
      optional_clusters: []
    },
    # Occupancy Sensor
    0x0107 => %{
      name: :occupancy_sensor,
      revision: 3,
      required_clusters: [@descriptor, @identify, @occupancy_sensing],
      optional_clusters: []
    },
    # Pump
    0x0303 => %{
      name: :pump,
      revision: 3,
      required_clusters: [@descriptor, @identify, @on_off, @pump_config],
      optional_clusters: [@level_control, @groups, @scenes, @temp_measurement, @pressure_measurement, @flow_measurement]
    },
    # Mode Select
    0x0027 => %{
      name: :mode_select,
      revision: 1,
      required_clusters: [@descriptor, @identify, @mode_select],
      optional_clusters: []
    },
    # Air Quality Sensor
    0x002C => %{
      name: :air_quality_sensor,
      revision: 1,
      required_clusters: [@descriptor, @identify, @air_quality],
      optional_clusters: [@temp_measurement, @humidity_measurement]
    },
    # Video Player
    0x0023 => %{
      name: :basic_video_player,
      revision: 2,
      required_clusters: [@descriptor, @media_playback, @on_off],
      optional_clusters: [@content_launcher, @audio_output]
    },
    # Power Source
    0x0011 => %{
      name: :power_source,
      revision: 1,
      required_clusters: [@descriptor, @power_source],
      optional_clusters: []
    }
  }

  @doc "Get device type definition by ID."
  @spec get(non_neg_integer()) :: device_type() | nil
  def get(device_type_id) do
    case Map.get(@device_types, device_type_id) do
      nil -> nil
      dt -> Map.put(dt, :id, device_type_id)
    end
  end

  @doc "List all known device type IDs."
  @spec list() :: [non_neg_integer()]
  def list, do: Map.keys(@device_types)

  @doc "Get device type name by ID."
  @spec name(non_neg_integer()) :: atom() | nil
  def name(device_type_id) do
    case Map.get(@device_types, device_type_id) do
      nil -> nil
      dt -> dt.name
    end
  end

  @doc "Check if a set of cluster IDs satisfies all required clusters for a device type."
  @spec validate(non_neg_integer(), [non_neg_integer()]) :: :ok | {:error, [non_neg_integer()]}
  def validate(device_type_id, cluster_ids) do
    case get(device_type_id) do
      nil ->
        :ok

      dt ->
        missing = dt.required_clusters -- cluster_ids
        if missing == [], do: :ok, else: {:error, missing}
    end
  end
end
