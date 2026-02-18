defmodule Matterlix.Cluster do
  @moduledoc """
  Behaviour and macro system for Matter clusters.

  Provides a declarative DSL for defining attributes and commands.
  Each cluster is a GenServer holding attribute state.

  ## Example

      defmodule MyCluster do
        use Matterlix.Cluster, id: 0x0006, name: :on_off

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
          writable: boolean()
        }

  @type cmd_def :: %{
          id: non_neg_integer(),
          name: atom(),
          params: keyword()
        }

  @callback cluster_id() :: non_neg_integer()
  @callback cluster_name() :: atom()
  @callback attribute_defs() :: [attr_def()]
  @callback command_defs() :: [cmd_def()]
  @callback handle_command(atom(), map(), map()) ::
              {:ok, term() | nil, map()} | {:error, atom()}

  @doc false
  def dispatch_command_reply(module, name, params, state) do
    case module.handle_command(name, params, state) do
      {:ok, response, new_state} -> {:reply, {:ok, response}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defmacro __using__(opts) do
    quote do
      @behaviour Matterlix.Cluster
      use GenServer

      import Matterlix.Cluster, only: [attribute: 4, attribute: 5, command: 3]

      Module.register_attribute(__MODULE__, :matter_attributes, accumulate: true)
      Module.register_attribute(__MODULE__, :matter_commands, accumulate: true)

      @cluster_id unquote(opts[:id])
      @cluster_name unquote(opts[:name])

      @before_compile Matterlix.Cluster

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: opts[:name])
      end

      def init(opts) do
        state =
          Enum.reduce(attribute_defs(), %{}, fn attr, acc ->
            value = Keyword.get(opts, attr.name, attr.default)
            Map.put(acc, attr.name, value)
          end)

        {:ok, state}
      end

      def handle_call({:read_attribute, name}, _from, state) do
        attr = Enum.find(attribute_defs(), &(&1.name == name))

        if attr do
          {:reply, {:ok, Map.get(state, name)}, state}
        else
          {:reply, {:error, :unsupported_attribute}, state}
        end
      end

      def handle_call({:write_attribute, name, value}, _from, state) do
        attr = Enum.find(attribute_defs(), &(&1.name == name))

        cond do
          attr == nil -> {:reply, {:error, :unsupported_attribute}, state}
          !attr.writable -> {:reply, {:error, :unsupported_write}, state}
          true -> {:reply, :ok, Map.put(state, name, value)}
        end
      end

      def handle_call({:invoke_command, name, params}, _from, state) do
        cmd = Enum.find(command_defs(), &(&1.name == name))

        if cmd do
          Matterlix.Cluster.dispatch_command_reply(
            __MODULE__, name, params, state
          )
        else
          {:reply, {:error, :unsupported_command}, state}
        end
      end

      def handle_call(:get_state, _from, state) do
        {:reply, state, state}
      end

      def get_attribute(state, name), do: Map.get(state, name)

      def set_attribute(state, name, value), do: Map.put(state, name, value)

      @impl Matterlix.Cluster
      def handle_command(_name, _params, _state), do: {:error, :unsupported_command}

      defoverridable init: 1, handle_command: 3
    end
  end

  defmacro __before_compile__(env) do
    attributes = Module.get_attribute(env.module, :matter_attributes) |> Enum.reverse()
    commands = Module.get_attribute(env.module, :matter_commands) |> Enum.reverse()

    quote do
      @impl Matterlix.Cluster
      def cluster_id, do: @cluster_id

      @impl Matterlix.Cluster
      def cluster_name, do: @cluster_name

      @impl Matterlix.Cluster
      def attribute_defs, do: unquote(Macro.escape(attributes))

      @impl Matterlix.Cluster
      def command_defs, do: unquote(Macro.escape(commands))
    end
  end

  defmacro attribute(id, name, type, opts) do
    quote do
      @matter_attributes %{
        id: unquote(id),
        name: unquote(name),
        type: unquote(type),
        default: unquote(Keyword.get(opts, :default)),
        writable: unquote(Keyword.get(opts, :writable, false))
      }
    end
  end

  defmacro attribute(id, name, type, default_opts, write_opts) do
    quote do
      @matter_attributes %{
        id: unquote(id),
        name: unquote(name),
        type: unquote(type),
        default: unquote(Keyword.get(default_opts ++ write_opts, :default)),
        writable: unquote(Keyword.get(default_opts ++ write_opts, :writable, false))
      }
    end
  end

  defmacro command(id, name, params) do
    quote do
      @matter_commands %{
        id: unquote(id),
        name: unquote(name),
        params: unquote(params)
      }
    end
  end
end
