defmodule MatterEx.Cluster do
  @moduledoc """
  Behaviour and macro system for Matter clusters.

  Provides a declarative DSL for defining attributes and commands.
  Each cluster is a GenServer holding attribute state.

  ## Example

      defmodule MyCluster do
        use MatterEx.Cluster, id: 0x0006, name: :on_off

        attribute 0x0000, :on_off, :boolean, default: false, writable: true
        attribute 0xFFFD, :cluster_revision, :uint16, default: 4

        command 0x00, :off, []
        command 0x01, :on, []

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

  defmacro __using__(opts) do
    quote do
      @behaviour MatterEx.Cluster
      use GenServer

      import MatterEx.Cluster, only: [attribute: 4, attribute: 5, command: 3, command: 4, event: 3]

      Module.register_attribute(__MODULE__, :matter_attributes, accumulate: true)
      Module.register_attribute(__MODULE__, :matter_commands, accumulate: true)
      Module.register_attribute(__MODULE__, :matter_events, accumulate: true)

      @cluster_id unquote(opts[:id])
      @cluster_name unquote(opts[:name])

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
          attr == nil -> {:reply, {:error, :unsupported_attribute}, state}
          !attr.writable -> {:reply, {:error, :unsupported_write}, state}
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

      def handle_call({:invoke_command, name, params, context}, from, state) do
        # Merge session context into params so clusters can access it
        params = Map.put(params, :_context, context)
        handle_call({:invoke_command, name, params}, from, state)
      end

      def handle_call({:invoke_command, name, params}, _from, state) do
        cmd = Enum.find(command_defs(), &(&1.name == name))

        if cmd do
          MatterEx.Cluster.dispatch_command_reply(
            __MODULE__, name, params, state
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
        global_attrs ++ [%{id: 0xFFFB, name: :attribute_list, type: :list, default: attr_list_value,
                          writable: false, fabric_scoped: false, min: nil, max: nil, enum_values: nil}]
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
      acc ++ [%{id: id, name: name, type: type, default: default, writable: false,
                fabric_scoped: false, min: nil, max: nil, enum_values: nil}]
    end
  end

  defmacro attribute(id, name, type, opts) do
    quote do
      @matter_attributes %{
        id: unquote(id),
        name: unquote(name),
        type: unquote(type),
        default: unquote(Keyword.get(opts, :default)),
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
    quote do
      @matter_attributes %{
        id: unquote(id),
        name: unquote(name),
        type: unquote(type),
        default: unquote(Keyword.get(all_opts, :default)),
        writable: unquote(Keyword.get(all_opts, :writable, false)),
        fabric_scoped: unquote(Keyword.get(all_opts, :fabric_scoped, false)),
        min: unquote(Keyword.get(all_opts, :min)),
        max: unquote(Keyword.get(all_opts, :max)),
        enum_values: unquote(Keyword.get(all_opts, :enum_values))
      }
    end
  end

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
