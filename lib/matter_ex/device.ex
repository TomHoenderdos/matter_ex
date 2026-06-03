defmodule MatterEx.Device do
  @moduledoc """
  Macro for defining a Matter device with endpoints and clusters.

  ## Example

      defmodule MyApp.Light do
        use MatterEx.Device,
          vendor: :test,
          product: :smart_light

        endpoint :light, :dimmable_light
      end

  This generates a Supervisor that starts all cluster GenServers,
  including an auto-generated endpoint 0 with Descriptor and
  BasicInformation clusters.
  """

  defmacro __using__(opts) do
    quote do
      import MatterEx.Device, only: [endpoint: 2, endpoint: 3, cluster: 1]

      Module.register_attribute(__MODULE__, :matter_endpoints, accumulate: true)
      Module.register_attribute(__MODULE__, :current_endpoint_clusters, accumulate: true)

      @device_opts unquote(normalize_device_opts(opts))

      @before_compile MatterEx.Device
    end
  end

  defmacro endpoint(id, device_type, do: block) when is_atom(device_type) do
    endpoint_definition(id, [device_type: device_type, auto_required_clusters: true], block)
  end

  defmacro endpoint(id, opts, do: block) when is_list(opts) do
    endpoint_definition(id, opts, block)
  end

  defmacro endpoint(id, device_type) when is_atom(device_type) do
    endpoint_definition(id, [device_type: device_type, auto_required_clusters: true], nil)
  end

  defmacro endpoint(id, opts) when is_list(opts) do
    endpoint_definition(id, opts, nil)
  end

  defp endpoint_definition(id, opts, block) do
    quote do
      Module.delete_attribute(__MODULE__, :current_endpoint_clusters)
      Module.register_attribute(__MODULE__, :current_endpoint_clusters, accumulate: true)
      unquote(block || quote(do: nil))

      @matter_endpoints {
        unquote(id),
        unquote(opts),
        Module.get_attribute(__MODULE__, :current_endpoint_clusters) |> Enum.reverse()
      }
    end
  end

  defmacro cluster(name) when is_atom(name) do
    module =
      MatterEx.Cluster.module_for_name(name) ||
        raise ArgumentError, "unknown cluster #{inspect(name)}"

    quote do
      @current_endpoint_clusters unquote(module)
    end
  end

  defmacro cluster(module) do
    quote do
      @current_endpoint_clusters unquote(module)
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defmacro __before_compile__(env) do
    user_endpoints =
      Module.get_attribute(env.module, :matter_endpoints) |> Enum.reverse()

    device_opts = Module.get_attribute(env.module, :device_opts)

    {user_endpoints, endpoint_aliases} = normalize_user_endpoints(user_endpoints)

    # Build endpoint 0 cluster list: Descriptor + BasicInformation + Commissioning
    ep0_clusters = [
      MatterEx.Cluster.Descriptor,
      MatterEx.Cluster.BasicInformation,
      MatterEx.Cluster.GeneralCommissioning,
      MatterEx.Cluster.OperationalCredentials,
      MatterEx.Cluster.AccessControl,
      MatterEx.Cluster.NetworkCommissioning,
      MatterEx.Cluster.GeneralDiagnostics,
      MatterEx.Cluster.TimeSynchronization,
      MatterEx.Cluster.ICDManagement,
      MatterEx.Cluster.ApplePrivate,
      MatterEx.Cluster.AdminCommissioning,
      MatterEx.Cluster.GroupKeyManagement
    ]

    # Auto-add Descriptor to user endpoints that don't already have it
    user_endpoints =
      Enum.map(user_endpoints, fn {id, opts, clusters} ->
        if MatterEx.Cluster.Descriptor in clusters do
          {id, opts, clusters}
        else
          {id, opts, [MatterEx.Cluster.Descriptor | clusters]}
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
    endpoint_alias_lookup = Map.new(endpoint_aliases)

    attribute_cluster_lookup = build_member_lookup(all_endpoints, :attribute_defs)
    command_cluster_lookup = build_member_lookup(all_endpoints, :command_defs)

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote do
      use Supervisor

      def start_link(opts \\ []) do
        Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def init(_opts) do
        children =
          unquote(
            Macro.escape(
              build_child_specs(
                env.module,
                all_endpoints,
                device_opts,
                parts_list,
                endpoint_server_lists
              )
            )
          )

        Supervisor.init(children, strategy: :one_for_one)
      end

      def __endpoints__, do: unquote(Macro.escape(all_endpoints))
      def __endpoint_ids__, do: unquote(Macro.escape(endpoint_ids))

      def __endpoint_id__(endpoint_ref) when is_integer(endpoint_ref) do
        if MapSet.member?(unquote(Macro.escape(endpoint_ids)), endpoint_ref) do
          endpoint_ref
        end
      end

      def __endpoint_id__(:root), do: 0

      def __endpoint_id__(endpoint_ref) when is_atom(endpoint_ref) do
        Map.get(unquote(Macro.escape(endpoint_alias_lookup)), endpoint_ref)
      end

      def __cluster_ids__(endpoint_id) do
        case __endpoint_id__(endpoint_id) do
          nil -> []
          endpoint_id -> Map.get(unquote(Macro.escape(endpoint_server_lists)), endpoint_id, [])
        end
      end

      def __cluster_module__(endpoint_id, cluster_id) do
        case __endpoint_id__(endpoint_id) do
          nil -> nil
          endpoint_id -> Map.get(unquote(Macro.escape(cluster_lookup)), {endpoint_id, cluster_id})
        end
      end

      def __process_name__(endpoint_id, cluster_name) do
        case __endpoint_id__(endpoint_id) do
          nil -> nil
          endpoint_id -> Map.get(unquote(Macro.escape(name_lookup)), {endpoint_id, cluster_name})
        end
      end

      def read_attribute(endpoint_id, cluster_name, attr_name) do
        with {:ok, endpoint_id} <- resolve_endpoint(endpoint_id),
             {:ok, name} <- resolve_process(endpoint_id, cluster_name) do
          GenServer.call(name, {:read_attribute, attr_name})
        end
      end

      def read_attribute(endpoint_id, attr_name) do
        with {:ok, endpoint_id} <- resolve_endpoint(endpoint_id),
             {:ok, cluster_name} <- resolve_attribute_cluster(endpoint_id, attr_name),
             {:ok, name} <- resolve_process(endpoint_id, cluster_name) do
          GenServer.call(name, {:read_attribute, attr_name})
        end
      end

      def write_attribute(endpoint_id, cluster_name, attr_name, value) do
        with {:ok, endpoint_id} <- resolve_endpoint(endpoint_id),
             {:ok, name} <- resolve_process(endpoint_id, cluster_name) do
          GenServer.call(name, {:write_attribute, attr_name, value})
        end
      end

      def write_attribute(endpoint_id, attr_name, value) do
        with {:ok, endpoint_id} <- resolve_endpoint(endpoint_id),
             {:ok, cluster_name} <- resolve_attribute_cluster(endpoint_id, attr_name),
             {:ok, name} <- resolve_process(endpoint_id, cluster_name) do
          GenServer.call(name, {:write_attribute, attr_name, value})
        end
      end

      def update_attribute(endpoint_id, cluster_name, attr_name, value) do
        with {:ok, endpoint_id} <- resolve_endpoint(endpoint_id),
             {:ok, name} <- resolve_process(endpoint_id, cluster_name) do
          GenServer.call(name, {:update_attribute, attr_name, value})
        end
      end

      def update_attribute(endpoint_id, attr_name, value) do
        with {:ok, endpoint_id} <- resolve_endpoint(endpoint_id),
             {:ok, cluster_name} <- resolve_attribute_cluster(endpoint_id, attr_name),
             {:ok, name} <- resolve_process(endpoint_id, cluster_name) do
          GenServer.call(name, {:update_attribute, attr_name, value})
        end
      end

      def invoke_command(endpoint_id, cluster_name, cmd_name, params \\ %{}) do
        with {:ok, endpoint_id} <- resolve_endpoint(endpoint_id),
             {:ok, name} <- resolve_process(endpoint_id, cluster_name) do
          name
          |> GenServer.call({:invoke_command, cmd_name, params})
          |> command_result_with_status(name, cluster_name)
        end
      end

      def invoke(endpoint_id, cmd_name, params \\ %{}) do
        with {:ok, endpoint_id} <- resolve_endpoint(endpoint_id),
             {:ok, cluster_name} <- resolve_command_cluster(endpoint_id, cmd_name),
             {:ok, name} <- resolve_process(endpoint_id, cluster_name) do
          name
          |> GenServer.call({:invoke_command, cmd_name, params})
          |> command_result_with_status(name, cluster_name)
        end
      end

      defp command_result_with_status({:ok, nil}, process_name, cluster_name) do
        case GenServer.call(process_name, {:read_attribute, cluster_name}) do
          {:ok, value} -> {:ok, value}
          {:error, :unsupported_attribute} -> {:ok, nil}
          {:error, _reason} -> {:ok, nil}
        end
      end

      defp command_result_with_status(result, _process_name, _cluster_name), do: result

      def endpoints do
        unquote(Macro.escape(endpoint_alias_lookup))
        |> Map.put(:root, 0)
      end

      def clusters(endpoint_id) do
        with {:ok, endpoint_id} <- resolve_endpoint(endpoint_id) do
          unquote(Macro.escape(all_endpoints))
          |> Enum.find_value([], fn
            {^endpoint_id, _opts, clusters} -> Enum.map(clusters, & &1.cluster_name())
            _other -> nil
          end)
        end
      end

      defp resolve_endpoint(endpoint_id) do
        case __endpoint_id__(endpoint_id) do
          nil -> {:error, :unsupported_endpoint}
          endpoint_id -> {:ok, endpoint_id}
        end
      end

      defp resolve_process(endpoint_id, cluster_name) do
        case __process_name__(endpoint_id, cluster_name) do
          nil -> {:error, :unsupported_cluster}
          name -> {:ok, name}
        end
      end

      defp resolve_attribute_cluster(endpoint_id, attr_name) do
        case Map.get(unquote(Macro.escape(attribute_cluster_lookup)), {endpoint_id, attr_name}) do
          nil -> {:error, :unsupported_attribute}
          :ambiguous -> {:error, :ambiguous_attribute}
          cluster_name -> {:ok, cluster_name}
        end
      end

      defp resolve_command_cluster(endpoint_id, cmd_name) do
        case Map.get(unquote(Macro.escape(command_cluster_lookup)), {endpoint_id, cmd_name}) do
          nil -> {:error, :unsupported_command}
          :ambiguous -> {:error, :ambiguous_command}
          cluster_name -> {:ok, cluster_name}
        end
      end
    end
  end

  defp normalize_user_endpoints(user_endpoints) do
    {endpoints, aliases, _used_ids, _used_aliases} =
      Enum.reduce(user_endpoints, {[], [], MapSet.new([0]), MapSet.new()}, fn
        {endpoint_ref, opts, clusters}, {endpoints, aliases, used_ids, used_aliases} ->
          {endpoint_id, endpoint_alias, used_ids} =
            normalize_endpoint_ref(endpoint_ref, used_ids)

          if endpoint_alias != nil and MapSet.member?(used_aliases, endpoint_alias) do
            raise ArgumentError, "duplicate endpoint alias #{inspect(endpoint_alias)}"
          end

          opts = normalize_endpoint_opts(opts, endpoint_ref, endpoint_alias)
          clusters = endpoint_clusters_from_device_type(opts) ++ clusters
          clusters = validate_endpoint_clusters(endpoint_ref, Enum.uniq(clusters))

          aliases =
            if endpoint_alias == nil do
              aliases
            else
              [{endpoint_alias, endpoint_id} | aliases]
            end

          used_aliases =
            if endpoint_alias == nil do
              used_aliases
            else
              MapSet.put(used_aliases, endpoint_alias)
            end

          {[{endpoint_id, opts, clusters} | endpoints], aliases, used_ids, used_aliases}
      end)

    {Enum.reverse(endpoints), Enum.reverse(aliases)}
  end

  defp normalize_endpoint_ref(endpoint_id, used_ids)
       when is_integer(endpoint_id) and endpoint_id > 0 do
    if MapSet.member?(used_ids, endpoint_id) do
      raise ArgumentError, "duplicate endpoint ID #{endpoint_id}"
    end

    {endpoint_id, nil, MapSet.put(used_ids, endpoint_id)}
  end

  defp normalize_endpoint_ref(0, _used_ids) do
    raise ArgumentError, "endpoint 0 is reserved for the root node"
  end

  defp normalize_endpoint_ref(endpoint_alias, used_ids) when is_atom(endpoint_alias) do
    endpoint_id =
      Stream.iterate(1, &(&1 + 1))
      |> Enum.find(&(not MapSet.member?(used_ids, &1)))

    {endpoint_id, endpoint_alias, MapSet.put(used_ids, endpoint_id)}
  end

  defp normalize_endpoint_ref(endpoint_ref, _used_ids) do
    raise ArgumentError, "invalid endpoint #{inspect(endpoint_ref)}"
  end

  defp normalize_endpoint_opts(opts, _endpoint_ref, endpoint_alias) do
    opts
    |> Keyword.update(:device_type, 0, &resolve_device_type!/1)
    |> maybe_put_endpoint_alias(endpoint_alias)
  end

  defp maybe_put_endpoint_alias(opts, nil), do: opts

  defp maybe_put_endpoint_alias(opts, endpoint_alias),
    do: Keyword.put(opts, :endpoint_alias, endpoint_alias)

  defp resolve_device_type!(device_type) when is_integer(device_type), do: device_type

  defp resolve_device_type!(device_type) when is_atom(device_type) do
    MatterEx.DeviceTypes.id_for_name(device_type) ||
      raise ArgumentError, "unknown device type #{inspect(device_type)}"
  end

  defp validate_endpoint_clusters(endpoint_ref, clusters) do
    cluster_names = Enum.map(clusters, & &1.cluster_name())
    duplicate = first_duplicate(cluster_names)

    if duplicate do
      raise ArgumentError,
            "duplicate cluster #{inspect(duplicate)} on endpoint #{inspect(endpoint_ref)}"
    end

    clusters
  end

  @development_vendor [
    vendor_name: "MatterEx Test",
    vendor_id: 0xFFF1
  ]

  @known_products %{
    smart_light: [
      product_name: "Smart Light",
      product_id: 0x8001
    ],
    temperature_sensor: [
      product_name: "Temperature Sensor",
      product_id: 0x8002
    ],
    matter_example: [
      product_name: "Matter Example Light + Sensors",
      product_id: 0x8000
    ],
    net_test: [
      product_name: "Matter Example Light + Sensors",
      product_id: 0x8000
    ]
  }

  @doc """
  Lists known vendor aliases that can be used with `use MatterEx.Device`.
  """
  @spec known_vendors() :: [{atom(), Keyword.t()}]
  def known_vendors do
    [test: @development_vendor]
  end

  @doc """
  Lists known product aliases that can be used with `use MatterEx.Device`.
  """
  @spec known_products() :: [{atom(), Keyword.t()}]
  def known_products do
    @known_products
    |> Map.to_list()
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Resolves a vendor ID from either a numeric ID or a known vendor alias.
  """
  @spec vendor_id!(non_neg_integer() | atom()) :: non_neg_integer()
  def vendor_id!(vendor_id) when is_integer(vendor_id), do: vendor_id

  def vendor_id!(:test), do: @development_vendor[:vendor_id]

  def vendor_id!(vendor), do: raise(ArgumentError, "unknown vendor #{inspect(vendor)}")

  @doc """
  Resolves a product ID from either a numeric ID or a known product alias.
  """
  @spec product_id!(non_neg_integer() | atom()) :: non_neg_integer()
  def product_id!(product_id) when is_integer(product_id), do: product_id

  def product_id!(product) when is_atom(product) do
    case Map.get(@known_products, product) do
      nil -> raise ArgumentError, "unknown product #{inspect(product)}"
      product_opts -> product_opts[:product_id]
    end
  end

  defp normalize_device_opts(opts) do
    opts
    |> expand_vendor_alias()
    |> expand_product_alias()
  end

  defp expand_vendor_alias(opts) do
    case Keyword.get(opts, :vendor) do
      nil ->
        opts

      :test ->
        Keyword.merge(@development_vendor, Keyword.delete(opts, :vendor))

      vendor ->
        raise ArgumentError, "unknown vendor #{inspect(vendor)}"
    end
  end

  defp expand_product_alias(opts) do
    case Keyword.get(opts, :product) do
      nil ->
        opts

      product ->
        case Map.get(@known_products, product) do
          nil -> raise ArgumentError, "unknown product #{inspect(product)}"
          product_opts -> Keyword.merge(product_opts, Keyword.delete(opts, :product))
        end
    end
  end

  defp endpoint_clusters_from_device_type(opts) do
    if Keyword.get(opts, :auto_required_clusters, false) do
      opts
      |> Keyword.get(:device_type, 0)
      |> MatterEx.DeviceTypes.get()
      |> case do
        nil ->
          []

        device_type ->
          device_type.required_clusters
          |> Enum.reject(&(&1 == MatterEx.Cluster.Descriptor.cluster_id()))
          |> Enum.map(&MatterEx.Cluster.module_for_id/1)
          |> Enum.reject(&is_nil/1)
      end
    else
      []
    end
  end

  defp first_duplicate(values) do
    Enum.reduce_while(values, MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value) do
        {:halt, value}
      else
        {:cont, MapSet.put(seen, value)}
      end
    end)
    |> case do
      %MapSet{} -> nil
      duplicate -> duplicate
    end
  end

  defp build_member_lookup(all_endpoints, defs_fun) do
    all_endpoints
    |> Enum.flat_map(fn {endpoint_id, _opts, clusters} ->
      Enum.flat_map(clusters, fn cluster ->
        cluster
        |> apply(defs_fun, [])
        |> Enum.map(&{{endpoint_id, &1.name}, cluster.cluster_name()})
      end)
    end)
    |> Enum.reduce(%{}, fn {key, cluster_name}, acc ->
      Map.update(acc, key, cluster_name, fn
        ^cluster_name -> cluster_name
        _other -> :ambiguous
      end)
    end)
  end

  # Build child specs at compile time
  defp build_child_specs(
         device_module,
         all_endpoints,
         device_opts,
         parts_list,
         endpoint_server_lists
       ) do
    event_store_name = :"#{device_module}.ep0.event_store"

    event_store_spec = %{
      id: event_store_name,
      start: {MatterEx.IM.EventStore, :start_link, [[name: event_store_name]]}
    }

    cluster_specs =
      Enum.flat_map(all_endpoints, fn {ep_id, ep_opts, clusters} ->
        Enum.map(clusters, fn cluster_mod ->
          name = :"#{device_module}.ep#{ep_id}.#{cluster_mod.cluster_name()}"

          init_opts =
            [name: name, endpoint: ep_id, event_store: event_store_name] ++
              cluster_init_opts(
                cluster_mod,
                ep_id,
                ep_opts,
                device_opts,
                parts_list,
                endpoint_server_lists
              )

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

  defp device_type_struct(id, revision \\ nil) do
    revision = revision || device_type_revision(id)
    %{@device_type_tag => {:uint, id}, @revision_tag => {:uint, revision}}
  end

  defp device_type_revision(id) do
    case MatterEx.DeviceTypes.get(id) do
      %{revision: revision} -> revision
      _ -> 1
    end
  end

  defp cluster_init_opts(
         MatterEx.Cluster.Descriptor,
         ep_id,
         ep_opts,
         _device_opts,
         parts_list,
         endpoint_server_lists
       ) do
    device_type_id = if ep_id == 0, do: 0x0016, else: Keyword.get(ep_opts, :device_type, 0)
    device_types = [device_type_struct(device_type_id)]

    [
      device_type_list: device_types,
      server_list: Map.get(endpoint_server_lists, ep_id, []),
      parts_list: if(ep_id == 0, do: parts_list, else: [])
    ]
  end

  defp cluster_init_opts(
         MatterEx.Cluster.BasicInformation,
         _ep_id,
         _ep_opts,
         device_opts,
         _parts_list,
         _endpoint_server_lists
       ) do
    Keyword.take(device_opts, [
      :vendor_name,
      :vendor_id,
      :product_name,
      :product_id,
      :node_label,
      :hardware_version,
      :hardware_version_string,
      :software_version,
      :software_version_string
    ])
  end

  defp cluster_init_opts(
         _mod,
         _ep_id,
         _ep_opts,
         _device_opts,
         _parts_list,
         _endpoint_server_lists
       ) do
    []
  end
end
