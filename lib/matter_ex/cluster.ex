defmodule MatterEx.Cluster do
  @moduledoc """
  Behaviour and macro system for Matter clusters.

  Provides a declarative DSL for defining attributes and commands.
  Each cluster is a GenServer holding attribute state.

  ## Example

      defmodule MyCluster do
        use MatterEx.Cluster, :on_off

        command :off
        command :on
        command :toggle

        def handle_command(:off, _params, state) do
          {:ok, nil, set_attribute(state, :on_off, false)}
        end

        def handle_command(:on, _params, state) do
          {:ok, nil, set_attribute(state, :on_off, true)}
        end
      end
  """

  @type attr_def :: %{
          id: non_neg_integer(),
          name: atom(),
          type: atom(),
          default: term(),
          writable: boolean(),
          fabric_scoped: boolean(),
          min: number() | nil,
          max: number() | nil,
          enum_values: [non_neg_integer()] | nil
        }

  @type cmd_def :: %{
          id: non_neg_integer(),
          name: atom(),
          params: keyword()
        }

  @type event_def :: %{
          id: non_neg_integer(),
          name: atom(),
          priority: non_neg_integer()
        }

  @callback cluster_id() :: non_neg_integer()
  @callback cluster_name() :: atom()
  @callback attribute_defs() :: [attr_def()]
  @callback command_defs() :: [cmd_def()]
  @callback event_defs() :: [event_def()]
  @callback handle_command(atom(), map(), map()) ::
              {:ok, term() | nil, map()} | {:error, atom()}

  @doc false
  def validate_constraint(attr, value) do
    cond do
      attr[:min] != nil and is_number(value) and value < attr.min ->
        {:error, :constraint_error}

      attr[:max] != nil and is_number(value) and value > attr.max ->
        {:error, :constraint_error}

      attr[:enum_values] != nil and is_integer(value) and value not in attr.enum_values ->
        {:error, :constraint_error}

      true ->
        :ok
    end
  end

  @doc false
  def dispatch_command_reply(module, name, params, state) do
    case module.handle_command(name, params, state) do
      {:ok, response, new_state} ->
        # Bump data_version if state changed
        new_state =
          if Map.drop(new_state, [:__data_version__]) != Map.drop(state, [:__data_version__]) do
            Map.update!(new_state, :__data_version__, &(&1 + 1))
          else
            new_state
          end

        {:reply, {:ok, response}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @known_cluster_ids %{
    identify: 0x0003,
    groups: 0x0004,
    scenes: 0x0005,
    on_off: 0x0006,
    level_control: 0x0008,
    descriptor: 0x001D,
    binding: 0x001E,
    access_control: 0x001F,
    basic_information: 0x0028,
    ota_software_update_provider: 0x0029,
    ota_software_update_requestor: 0x002A,
    localization_configuration: 0x002B,
    time_format_localization: 0x002C,
    unit_localization: 0x002D,
    power_source: 0x002F,
    general_commissioning: 0x0030,
    network_commissioning: 0x0031,
    general_diagnostics: 0x0033,
    software_diagnostics: 0x0034,
    wifi_network_diagnostics: 0x0036,
    ethernet_network_diagnostics: 0x0037,
    time_synchronization: 0x0038,
    switch: 0x003B,
    admin_commissioning: 0x003C,
    operational_credentials: 0x003E,
    group_key_management: 0x003F,
    fixed_label: 0x0040,
    user_label: 0x0041,
    boolean_state: 0x0045,
    icd_management: 0x0046,
    mode_select: 0x0050,
    laundry_washer_controls: 0x0053,
    refrigerator_alarm: 0x0057,
    air_quality: 0x005B,
    smoke_co_alarm: 0x005C,
    dishwasher_alarm: 0x005D,
    boolean_state_configuration: 0x0080,
    valve_configuration_and_control: 0x0081,
    device_energy_management: 0x0098,
    energy_preference: 0x009B,
    power_topology: 0x009C,
    door_lock: 0x0101,
    window_covering: 0x0102,
    pump_configuration_and_control: 0x0200,
    thermostat: 0x0201,
    fan_control: 0x0202,
    color_control: 0x0300,
    illuminance_measurement: 0x0400,
    temperature_measurement: 0x0402,
    pressure_measurement: 0x0403,
    flow_measurement: 0x0404,
    relative_humidity_measurement: 0x0405,
    occupancy_sensing: 0x0406,
    carbon_dioxide_concentration_measurement: 0x040D,
    pm25_concentration_measurement: 0x042A,
    pm10_concentration_measurement: 0x042D,
    tvoc_concentration_measurement: 0x042E,
    media_playback: 0x0506,
    content_launcher: 0x050A,
    audio_output: 0x050B,
    electrical_measurement: 0x0B04,
    apple_private: 0x1349FC00
  }

  @known_attribute_ids %{
    on_off: %{
      on_off: 0x0000
    }
  }

  @known_command_ids %{
    on_off: %{
      off: 0x00,
      on: 0x01,
      toggle: 0x02
    }
  }

  @known_cluster_modules %{
    access_control: MatterEx.Cluster.AccessControl,
    admin_commissioning: MatterEx.Cluster.AdminCommissioning,
    air_quality: MatterEx.Cluster.AirQuality,
    apple_private: MatterEx.Cluster.ApplePrivate,
    audio_output: MatterEx.Cluster.AudioOutput,
    basic_information: MatterEx.Cluster.BasicInformation,
    binding: MatterEx.Cluster.Binding,
    boolean_state: MatterEx.Cluster.BooleanState,
    boolean_state_configuration: MatterEx.Cluster.BooleanStateConfiguration,
    carbon_dioxide_concentration_measurement:
      MatterEx.Cluster.CarbonDioxideConcentrationMeasurement,
    color_control: MatterEx.Cluster.ColorControl,
    content_launcher: MatterEx.Cluster.ContentLauncher,
    descriptor: MatterEx.Cluster.Descriptor,
    device_energy_management: MatterEx.Cluster.DeviceEnergyManagement,
    dishwasher_alarm: MatterEx.Cluster.DishwasherAlarm,
    door_lock: MatterEx.Cluster.DoorLock,
    electrical_measurement: MatterEx.Cluster.ElectricalMeasurement,
    energy_preference: MatterEx.Cluster.EnergyPreference,
    ethernet_network_diagnostics: MatterEx.Cluster.EthernetNetworkDiagnostics,
    fan_control: MatterEx.Cluster.FanControl,
    fixed_label: MatterEx.Cluster.FixedLabel,
    flow_measurement: MatterEx.Cluster.FlowMeasurement,
    general_commissioning: MatterEx.Cluster.GeneralCommissioning,
    general_diagnostics: MatterEx.Cluster.GeneralDiagnostics,
    group_key_management: MatterEx.Cluster.GroupKeyManagement,
    groups: MatterEx.Cluster.Groups,
    icd_management: MatterEx.Cluster.ICDManagement,
    identify: MatterEx.Cluster.Identify,
    illuminance_measurement: MatterEx.Cluster.IlluminanceMeasurement,
    laundry_washer_controls: MatterEx.Cluster.LaundryWasherControls,
    level_control: MatterEx.Cluster.LevelControl,
    localization_configuration: MatterEx.Cluster.LocalizationConfiguration,
    media_playback: MatterEx.Cluster.MediaPlayback,
    mode_select: MatterEx.Cluster.ModeSelect,
    network_commissioning: MatterEx.Cluster.NetworkCommissioning,
    occupancy_sensing: MatterEx.Cluster.OccupancySensing,
    on_off: MatterEx.Cluster.OnOff,
    operational_credentials: MatterEx.Cluster.OperationalCredentials,
    ota_software_update_provider: MatterEx.Cluster.OTASoftwareUpdateProvider,
    ota_software_update_requestor: MatterEx.Cluster.OTASoftwareUpdateRequestor,
    pm10_concentration_measurement: MatterEx.Cluster.PM10ConcentrationMeasurement,
    pm25_concentration_measurement: MatterEx.Cluster.PM25ConcentrationMeasurement,
    power_source: MatterEx.Cluster.PowerSource,
    power_topology: MatterEx.Cluster.PowerTopology,
    pressure_measurement: MatterEx.Cluster.PressureMeasurement,
    pump_configuration_and_control: MatterEx.Cluster.PumpConfigurationAndControl,
    refrigerator_alarm: MatterEx.Cluster.RefrigeratorAlarm,
    relative_humidity_measurement: MatterEx.Cluster.RelativeHumidityMeasurement,
    scenes: MatterEx.Cluster.Scenes,
    smoke_co_alarm: MatterEx.Cluster.SmokeCOAlarm,
    software_diagnostics: MatterEx.Cluster.SoftwareDiagnostics,
    switch: MatterEx.Cluster.Switch,
    temperature_measurement: MatterEx.Cluster.TemperatureMeasurement,
    thermostat: MatterEx.Cluster.Thermostat,
    time_format_localization: MatterEx.Cluster.TimeFormatLocalization,
    time_synchronization: MatterEx.Cluster.TimeSynchronization,
    tvoc_concentration_measurement:
      MatterEx.Cluster.TotalVolatileOrganicCompoundsConcentrationMeasurement,
    unit_localization: MatterEx.Cluster.UnitLocalization,
    user_label: MatterEx.Cluster.UserLabel,
    valve_configuration_and_control: MatterEx.Cluster.ValveConfigurationAndControl,
    wifi_network_diagnostics: MatterEx.Cluster.WiFiNetworkDiagnostics,
    window_covering: MatterEx.Cluster.WindowCovering
  }

  @doc """
  Returns the built-in cluster names accepted by `use MatterEx.Cluster, name`.

  The returned keyword list is sorted by cluster name and maps each friendly DSL
  name to its Matter cluster ID.
  """
  @spec known_clusters() :: [{atom(), non_neg_integer()}]
  def known_clusters do
    @known_cluster_ids
    |> Map.to_list()
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Resolves a built-in cluster name to its module.
  """
  @spec module_for_name(atom()) :: module() | nil
  def module_for_name(cluster_name) when is_atom(cluster_name) do
    Map.get(@known_cluster_modules, cluster_name)
  end

  @doc """
  Resolves a built-in cluster ID to its module.
  """
  @spec module_for_id(non_neg_integer()) :: module() | nil
  def module_for_id(cluster_id) do
    case Enum.find(@known_cluster_ids, fn {_name, id} -> id == cluster_id end) do
      {name, _id} -> module_for_name(name)
      nil -> nil
    end
  end

  @doc """
  Resolves a built-in attribute name to its Matter attribute ID.
  """
  @spec attribute_id_for(atom(), atom()) :: non_neg_integer() | nil
  def attribute_id_for(cluster_name, attribute_name)
      when is_atom(cluster_name) and is_atom(attribute_name) do
    known_attribute_id(cluster_name, attribute_name)
  end

  @doc """
  Resolves a built-in command name to its Matter command ID.
  """
  @spec command_id_for(atom(), atom()) :: non_neg_integer() | nil
  def command_id_for(cluster_name, command_name)
      when is_atom(cluster_name) and is_atom(command_name) do
    known_command_id(cluster_name, command_name)
  end

  defmacro __using__(name) when is_atom(name) do
    cluster_using([name: name], __CALLER__)
  end

  defmacro __using__(opts) when is_list(opts) do
    cluster_using(opts, __CALLER__)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp cluster_using(opts, caller) do
    name = Keyword.fetch!(opts, :name)
    id = Keyword.get(opts, :id, known_cluster_id(name))

    if id == nil do
      raise ArgumentError, "cluster #{inspect(name)} requires an :id option"
    end

    Module.register_attribute(caller.module, :matter_cluster_name, persist: false)
    Module.put_attribute(caller.module, :matter_cluster_name, name)

    quote do
      @behaviour MatterEx.Cluster
      use GenServer

      import MatterEx.Cluster,
        only: [
          attribute: 2,
          attribute: 3,
          attribute: 4,
          attribute: 5,
          command: 1,
          command: 2,
          command: 3,
          command: 4,
          event: 3,
          revision: 1
        ]

      Module.register_attribute(__MODULE__, :matter_attributes, accumulate: true)
      Module.register_attribute(__MODULE__, :matter_commands, accumulate: true)
      Module.register_attribute(__MODULE__, :matter_events, accumulate: true)

      @cluster_id unquote(id)
      @cluster_name unquote(name)

      @before_compile MatterEx.Cluster

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: opts[:name])
      end

      @impl true
      def init(opts) do
        state =
          Enum.reduce(attribute_defs(), %{__data_version__: 0}, fn attr, acc ->
            value = Keyword.get(opts, attr.name, attr.default)
            Map.put(acc, attr.name, value)
          end)

        {:ok, state}
      end

      @impl true
      def handle_call({:read_attribute, name}, _from, state) do
        attr = Enum.find(attribute_defs(), &(&1.name == name))

        if attr do
          {:reply, {:ok, Map.get(state, name)}, state}
        else
          {:reply, {:error, :unsupported_attribute}, state}
        end
      end

      def handle_call(:read_data_version, _from, state) do
        {:reply, state.__data_version__, state}
      end

      def handle_call({:write_attribute, name, value}, _from, state) do
        attr = Enum.find(attribute_defs(), &(&1.name == name))

        cond do
          attr == nil ->
            {:reply, {:error, :unsupported_attribute}, state}

          !attr.writable ->
            {:reply, {:error, :unsupported_write}, state}

          true ->
            case MatterEx.Cluster.validate_constraint(attr, value) do
              :ok ->
                state = state |> Map.put(name, value) |> bump_data_version()
                {:reply, :ok, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
        end
      end

      def handle_call({:update_attribute, name, value}, _from, state) do
        attr = Enum.find(attribute_defs(), &(&1.name == name))

        if attr == nil do
          {:reply, {:error, :unsupported_attribute}, state}
        else
          case MatterEx.Cluster.validate_constraint(attr, value) do
            :ok ->
              state = state |> Map.put(name, value) |> bump_data_version()
              {:reply, :ok, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end
      end

      def handle_call({:invoke_command, name, params, context}, from, state) do
        # Merge session context into params so clusters can access it
        params = Map.put(params, :_context, context)
        handle_call({:invoke_command, name, params}, from, state)
      end

      def handle_call({:invoke_command, name, params}, _from, state) do
        cmd = Enum.find(command_defs(), &(&1.name == name))

        if cmd do
          MatterEx.Cluster.dispatch_command_reply(
            __MODULE__,
            name,
            params,
            state
          )
        else
          {:reply, {:error, :unsupported_command}, state}
        end
      end

      def handle_call(:get_state, _from, state) do
        {:reply, state, state}
      end

      defp bump_data_version(state) do
        Map.update!(state, :__data_version__, &(&1 + 1))
      end

      def get_attribute(state, name), do: Map.get(state, name)

      def set_attribute(state, name, value), do: Map.put(state, name, value)

      @impl MatterEx.Cluster
      def handle_command(_name, _params, _state), do: {:error, :unsupported_command}

      defoverridable init: 1, handle_command: 3
    end
  end

  defmacro __before_compile__(env) do
    user_attributes = Module.get_attribute(env.module, :matter_attributes) |> Enum.reverse()
    commands = Module.get_attribute(env.module, :matter_commands) |> Enum.reverse()
    events = Module.get_attribute(env.module, :matter_events) |> Enum.reverse()
    cluster_name = Module.get_attribute(env.module, :matter_cluster_name)
    user_attributes = maybe_add_cluster_revision(user_attributes, cluster_name)
    user_attributes = maybe_add_known_attributes(user_attributes, cluster_name, env.module)

    # Auto-generate global attributes that aren't already declared
    declared_ids = MapSet.new(user_attributes, & &1.id)

    # Compute generated_command_list: response_ids from commands that have one
    generated_cmd_ids =
      commands
      |> Enum.map(& &1.response_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    # Compute accepted_command_list: all command IDs
    accepted_cmd_ids = commands |> Enum.map(& &1.id) |> Enum.sort()

    # Compute event_list: all event IDs
    event_ids = events |> Enum.map(& &1.id) |> Enum.sort()

    # Build the global attributes to inject
    global_attrs =
      []
      |> maybe_add_global(declared_ids, 0xFFFC, :feature_map, :uint32, 0)
      |> maybe_add_global(declared_ids, 0xFFF8, :generated_command_list, :list, generated_cmd_ids)
      |> maybe_add_global(declared_ids, 0xFFF9, :accepted_command_list, :list, accepted_cmd_ids)
      |> maybe_add_global(declared_ids, 0xFFFA, :event_list, :list, event_ids)

    # AttributeList must include all IDs (user + globals + itself)
    all_attr_ids_so_far =
      (user_attributes ++ global_attrs)
      |> Enum.map(& &1.id)

    global_attrs =
      if MapSet.member?(declared_ids, 0xFFFB) do
        global_attrs
      else
        attr_list_value = Enum.sort([0xFFFB | all_attr_ids_so_far])

        global_attrs ++
          [
            %{
              id: 0xFFFB,
              name: :attribute_list,
              type: :list,
              default: attr_list_value,
              writable: false,
              fabric_scoped: false,
              min: nil,
              max: nil,
              enum_values: nil
            }
          ]
      end

    attributes = user_attributes ++ global_attrs

    quote do
      @impl MatterEx.Cluster
      def cluster_id, do: @cluster_id

      @impl MatterEx.Cluster
      def cluster_name, do: @cluster_name

      @impl MatterEx.Cluster
      def attribute_defs, do: unquote(Macro.escape(attributes))

      @impl MatterEx.Cluster
      def command_defs, do: unquote(Macro.escape(commands))

      @impl MatterEx.Cluster
      def event_defs, do: unquote(Macro.escape(events))
    end
  end

  defp maybe_add_global(acc, declared_ids, id, name, type, default) do
    if MapSet.member?(declared_ids, id) do
      acc
    else
      acc ++
        [
          %{
            id: id,
            name: name,
            type: type,
            default: default,
            writable: false,
            fabric_scoped: false,
            min: nil,
            max: nil,
            enum_values: nil
          }
        ]
    end
  end

  defp maybe_add_cluster_revision(attributes, cluster_name) do
    if Enum.any?(attributes, &(&1.id == 0xFFFD)) do
      attributes
    else
      attributes ++
        [
          %{
            id: 0xFFFD,
            name: :cluster_revision,
            type: :uint16,
            default: known_cluster_revision(cluster_name) || 1,
            writable: false,
            fabric_scoped: false,
            min: nil,
            max: nil,
            enum_values: nil
          }
        ]
    end
  end

  defp maybe_add_known_attributes(attributes, cluster_name, current_module) do
    seen_ids = MapSet.new(attributes, & &1.id)
    seen_names = MapSet.new(attributes, & &1.name)

    known_attribute_defs(cluster_name, current_module)
    |> Enum.reject(
      &(global_attribute?(&1) or MapSet.member?(seen_ids, &1.id) or
          MapSet.member?(seen_names, &1.name))
    )
    |> then(&(attributes ++ &1))
  end

  defp known_attribute_defs(cluster_name, current_module) do
    with module when not is_nil(module) <- module_for_name(cluster_name),
         false <- module == current_module,
         {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :attribute_defs, 0) do
      module.attribute_defs()
    else
      _other -> []
    end
  end

  defp global_attribute?(%{id: id}) when id in 0xFFF8..0xFFFD, do: true
  defp global_attribute?(_attr), do: false

  defmacro attribute(name, type) when is_atom(name) do
    quote do
      attribute(unquote(name), unquote(type), [])
    end
  end

  defmacro attribute(id, name, type, opts) do
    default = attribute_default(opts, type)

    quote do
      @matter_attributes %{
        id: unquote(id),
        name: unquote(name),
        type: unquote(type),
        default: unquote(default),
        writable: unquote(Keyword.get(opts, :writable, false)),
        fabric_scoped: unquote(Keyword.get(opts, :fabric_scoped, false)),
        min: unquote(Keyword.get(opts, :min)),
        max: unquote(Keyword.get(opts, :max)),
        enum_values: unquote(Keyword.get(opts, :enum_values))
      }
    end
  end

  defmacro attribute(name, type, opts) when is_atom(name) and is_list(opts) do
    cluster_name = caller_cluster_name(__CALLER__)
    {id, opts} = Keyword.pop(opts, :id, known_attribute_id(cluster_name, name))

    if id == nil do
      raise ArgumentError,
            "attribute #{inspect(name)} requires an :id option for cluster #{inspect(cluster_name)}"
    end

    default = attribute_default(opts, type)

    quote do
      @matter_attributes %{
        id: unquote(id),
        name: unquote(name),
        type: unquote(type),
        default: unquote(default),
        writable: unquote(Keyword.get(opts, :writable, false)),
        fabric_scoped: unquote(Keyword.get(opts, :fabric_scoped, false)),
        min: unquote(Keyword.get(opts, :min)),
        max: unquote(Keyword.get(opts, :max)),
        enum_values: unquote(Keyword.get(opts, :enum_values))
      }
    end
  end

  defmacro attribute(id, name, type, default_opts, write_opts) do
    all_opts = default_opts ++ write_opts
    default = attribute_default(all_opts, type)

    quote do
      @matter_attributes %{
        id: unquote(id),
        name: unquote(name),
        type: unquote(type),
        default: unquote(default),
        writable: unquote(Keyword.get(all_opts, :writable, false)),
        fabric_scoped: unquote(Keyword.get(all_opts, :fabric_scoped, false)),
        min: unquote(Keyword.get(all_opts, :min)),
        max: unquote(Keyword.get(all_opts, :max)),
        enum_values: unquote(Keyword.get(all_opts, :enum_values))
      }
    end
  end

  defp attribute_default(opts, :boolean), do: Keyword.get(opts, :default, false)
  defp attribute_default(opts, _type), do: Keyword.get(opts, :default)

  defmacro command(id, name, params) do
    quote do
      @matter_commands %{
        id: unquote(id),
        name: unquote(name),
        params: unquote(params),
        response_id: nil
      }
    end
  end

  defmacro command(name) when is_atom(name) do
    command_definition(name, [], __CALLER__)
  end

  defmacro command(name, opts) when is_atom(name) and is_list(opts) do
    command_definition(name, opts, __CALLER__)
  end

  defp command_definition(name, opts, caller) do
    cluster_name = caller_cluster_name(caller)
    {id, opts} = Keyword.pop(opts, :id, known_command_id(cluster_name, name))

    if id == nil do
      raise ArgumentError,
            "command #{inspect(name)} requires an :id option for cluster #{inspect(cluster_name)}"
    end

    quote do
      @matter_commands %{
        id: unquote(id),
        name: unquote(name),
        params: unquote(Keyword.get(opts, :params, [])),
        response_id: unquote(Keyword.get(opts, :response_id))
      }
    end
  end

  defmacro command(id, name, params, opts) do
    quote do
      @matter_commands %{
        id: unquote(id),
        name: unquote(name),
        params: unquote(params),
        response_id: unquote(Keyword.get(opts, :response_id))
      }
    end
  end

  defmacro revision(version) do
    quote do
      @matter_attributes %{
        id: 0xFFFD,
        name: :cluster_revision,
        type: :uint16,
        default: unquote(version),
        writable: false,
        fabric_scoped: false,
        min: nil,
        max: nil,
        enum_values: nil
      }
    end
  end

  defp caller_cluster_name(caller) do
    Module.get_attribute(caller.module, :matter_cluster_name) ||
      Module.get_attribute(caller.module, :cluster_name) ||
      module_cluster_name(caller.module)
  end

  defp module_cluster_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp known_attribute_id(cluster_name, attribute_name) do
    get_in(@known_attribute_ids, [cluster_name, attribute_name]) ||
      lookup_member_id(cluster_name, attribute_name, :attribute_defs)
  end

  defp known_command_id(cluster_name, command_name) do
    get_in(@known_command_ids, [cluster_name, command_name]) ||
      lookup_member_id(cluster_name, command_name, :command_defs)
  end

  defp known_cluster_revision(cluster_name) do
    with module when not is_nil(module) <- module_for_name(cluster_name),
         {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :attribute_defs, 0),
         %{default: revision} <-
           Enum.find(module.attribute_defs(), &(&1.name == :cluster_revision)) do
      revision
    else
      _other -> nil
    end
  end

  defp known_cluster_id(cluster_name) do
    Map.get(@known_cluster_ids, cluster_name)
  end

  defp lookup_member_id(cluster_name, member_name, defs_fun) do
    with module when not is_nil(module) <- module_for_name(cluster_name),
         {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, defs_fun, 0),
         %{id: id} <- Enum.find(apply(module, defs_fun, []), &(&1.name == member_name)) do
      id
    else
      _other -> nil
    end
  end

  @priority_map %{debug: 0, info: 1, critical: 2}

  defmacro event(id, name, priority) do
    priority_val = Map.fetch!(@priority_map, priority)

    quote do
      @matter_events %{
        id: unquote(id),
        name: unquote(name),
        priority: unquote(priority_val)
      }
    end
  end
end
