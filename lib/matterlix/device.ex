defmodule Matterlix.Device do
  @moduledoc """
  Macro for defining a Matter device with endpoints and clusters.

  ## Example

      defmodule MyApp.Light do
        use Matterlix.Device,
          vendor_name: "My Company",
          product_name: "Smart Light",
          vendor_id: 0xFFF1,
          product_id: 0x8001

        endpoint 1, device_type: 0x0100 do
          cluster Matterlix.Cluster.OnOff
        end
      end

  This generates a Supervisor that starts all cluster GenServers,
  including an auto-generated endpoint 0 with Descriptor and
  BasicInformation clusters.
  """

  defmacro __using__(opts) do
    quote do
      import Matterlix.Device, only: [endpoint: 3, cluster: 1]

      Module.register_attribute(__MODULE__, :matter_endpoints, accumulate: true)
      Module.register_attribute(__MODULE__, :current_endpoint_clusters, accumulate: true)

      @device_opts unquote(opts)

      @before_compile Matterlix.Device
    end
  end

  defmacro endpoint(id, opts, do: block) do
    quote do
      Module.delete_attribute(__MODULE__, :current_endpoint_clusters)
      Module.register_attribute(__MODULE__, :current_endpoint_clusters, accumulate: true)
      unquote(block)

      @matter_endpoints {
        unquote(id),
        unquote(opts),
        Module.get_attribute(__MODULE__, :current_endpoint_clusters) |> Enum.reverse()
      }
    end
  end

  defmacro cluster(module) do
    quote do
      @current_endpoint_clusters unquote(module)
    end
  end

  defmacro __before_compile__(env) do
    user_endpoints =
      Module.get_attribute(env.module, :matter_endpoints) |> Enum.reverse()

    device_opts = Module.get_attribute(env.module, :device_opts)

    # Build endpoint 0 cluster list: Descriptor + BasicInformation + Commissioning
    ep0_clusters = [
      Matterlix.Cluster.Descriptor,
      Matterlix.Cluster.BasicInformation,
      Matterlix.Cluster.GeneralCommissioning,
      Matterlix.Cluster.OperationalCredentials,
      Matterlix.Cluster.AccessControl,
      Matterlix.Cluster.NetworkCommissioning,
      Matterlix.Cluster.GroupKeyManagement
    ]

    # Auto-add Descriptor to user endpoints that don't already have it
    user_endpoints =
      Enum.map(user_endpoints, fn {id, opts, clusters} ->
        if Matterlix.Cluster.Descriptor in clusters do
          {id, opts, clusters}
        else
          {id, opts, [Matterlix.Cluster.Descriptor | clusters]}
        end
      end)

    # Collect all endpoints (0 + user-defined)
    all_endpoints = [{0, [], ep0_clusters} | user_endpoints]

    # Build parts list (all non-zero endpoint IDs)
    parts_list = for {id, _opts, _clusters} <- user_endpoints, do: id

    # Build per-endpoint server lists (cluster IDs)
    endpoint_server_lists =
      for {id, _opts, clusters} <- all_endpoints, into: %{} do
        {id, Enum.map(clusters, & &1.cluster_id())}
      end

    # Build cluster module lookup: {endpoint_id, cluster_id} => module
    cluster_lookup =
      for {ep_id, _opts, clusters} <- all_endpoints,
          mod <- clusters,
          into: %{} do
        {{ep_id, mod.cluster_id()}, mod}
      end

    # Build process name lookup: {endpoint_id, cluster_name} => registered name
    name_lookup =
      for {ep_id, _opts, clusters} <- all_endpoints,
          mod <- clusters,
          into: %{} do
        {{ep_id, mod.cluster_name()}, :"#{env.module}.ep#{ep_id}.#{mod.cluster_name()}"}
      end

    # Add event_store process name
    event_store_name = :"#{env.module}.ep0.event_store"
    name_lookup = Map.put(name_lookup, {0, :event_store}, event_store_name)

    # Endpoint IDs set
    endpoint_ids = MapSet.new(for {id, _opts, _clusters} <- all_endpoints, do: id)

    quote do
      use Supervisor

      def start_link(opts \\ []) do
        Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def init(_opts) do
        children = unquote(Macro.escape(build_child_specs(env.module, all_endpoints, device_opts, parts_list, endpoint_server_lists)))
        Supervisor.init(children, strategy: :one_for_one)
      end

      def __endpoints__, do: unquote(Macro.escape(all_endpoints))
      def __endpoint_ids__, do: unquote(Macro.escape(endpoint_ids))

      def __cluster_ids__(endpoint_id) do
        Map.get(unquote(Macro.escape(endpoint_server_lists)), endpoint_id, [])
      end

      def __cluster_module__(endpoint_id, cluster_id) do
        Map.get(unquote(Macro.escape(cluster_lookup)), {endpoint_id, cluster_id})
      end

      def __process_name__(endpoint_id, cluster_name) do
        Map.get(unquote(Macro.escape(name_lookup)), {endpoint_id, cluster_name})
      end

      def read_attribute(endpoint_id, cluster_name, attr_name) do
        case __process_name__(endpoint_id, cluster_name) do
          nil -> {:error, :unsupported_cluster}
          name -> GenServer.call(name, {:read_attribute, attr_name})
        end
      end

      def write_attribute(endpoint_id, cluster_name, attr_name, value) do
        case __process_name__(endpoint_id, cluster_name) do
          nil -> {:error, :unsupported_cluster}
          name -> GenServer.call(name, {:write_attribute, attr_name, value})
        end
      end

      def invoke_command(endpoint_id, cluster_name, cmd_name, params \\ %{}) do
        case __process_name__(endpoint_id, cluster_name) do
          nil -> {:error, :unsupported_cluster}
          name -> GenServer.call(name, {:invoke_command, cmd_name, params})
        end
      end
    end
  end

  # Build child specs at compile time
  defp build_child_specs(device_module, all_endpoints, device_opts, parts_list, endpoint_server_lists) do
    event_store_name = :"#{device_module}.ep0.event_store"

    event_store_spec = %{
      id: event_store_name,
      start: {Matterlix.IM.EventStore, :start_link, [[name: event_store_name]]}
    }

    cluster_specs =
      Enum.flat_map(all_endpoints, fn {ep_id, ep_opts, clusters} ->
        Enum.map(clusters, fn cluster_mod ->
          name = :"#{device_module}.ep#{ep_id}.#{cluster_mod.cluster_name()}"

          init_opts =
            [name: name, endpoint: ep_id, event_store: event_store_name] ++
              cluster_init_opts(cluster_mod, ep_id, ep_opts, device_opts, parts_list, endpoint_server_lists)

          %{
            id: name,
            start: {cluster_mod, :start_link, [init_opts]}
          }
        end)
      end)

    # EventStore must start before clusters so clusters can emit events in init
    [event_store_spec | cluster_specs]
  end

  # Matter DeviceTypeStruct context tags (spec section 11.1.5.1)
  @device_type_tag 0
  @revision_tag 1

  defp device_type_struct(id, revision \\ 1) do
    %{@device_type_tag => {:uint, id}, @revision_tag => {:uint, revision}}
  end

  defp cluster_init_opts(Matterlix.Cluster.Descriptor, ep_id, ep_opts, _device_opts, parts_list, endpoint_server_lists) do
    device_type_id = if ep_id == 0, do: 0x0016, else: Keyword.get(ep_opts, :device_type, 0)
    device_types = [device_type_struct(device_type_id)]

    [
      device_type_list: device_types,
      server_list: Map.get(endpoint_server_lists, ep_id, []),
      parts_list: if(ep_id == 0, do: parts_list, else: [])
    ]
  end

  defp cluster_init_opts(Matterlix.Cluster.BasicInformation, _ep_id, _ep_opts, device_opts, _parts_list, _endpoint_server_lists) do
    Keyword.take(device_opts, [
      :vendor_name, :vendor_id, :product_name, :product_id,
      :node_label, :hardware_version, :hardware_version_string,
      :software_version, :software_version_string
    ])
  end

  defp cluster_init_opts(_mod, _ep_id, _ep_opts, _device_opts, _parts_list, _endpoint_server_lists) do
    []
  end
end
