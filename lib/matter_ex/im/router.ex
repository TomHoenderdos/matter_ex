defmodule MatterEx.IM.Router do
  @moduledoc """
  Routes IM messages to cluster GenServers.

  Bridges the IM codec layer (Phase 5) to the cluster runtime (Phase 6).
  All functions are pure — the router itself has no state.
  """

  alias MatterEx.{ACL, IM}
  alias MatterEx.IM.{EventStore, Status}

  require Logger

  @doc """
  Dispatch an IM message to the appropriate cluster(s) and return the response.

  The optional `context` parameter carries session identity for ACL enforcement.
  Defaults to PASE context (implicit admin, bypasses ACL).
  """
  @spec handle(module(), atom(), struct(), map()) :: struct()
  def handle(device, opcode, request, context \\ %{auth_mode: :pase})

  def handle(device, :read_request, %IM.ReadRequest{} = req, context),
    do: handle_read(device, req, context)

  def handle(device, :write_request, %IM.WriteRequest{} = req, context),
    do: handle_write(device, req, context)

  def handle(device, :invoke_request, %IM.InvokeRequest{} = req, context),
    do: handle_invoke(device, req, context)

  def handle(_device, :timed_request, %IM.TimedRequest{}, _context) do
    %IM.StatusResponse{status: 0}
  end

  def handle(_device, :subscribe_request, %IM.SubscribeRequest{} = req, _context) do
    # Returns SubscribeResponse with negotiated max_interval.
    # The subscription_id is injected by MessageHandler which pre-processes
    # the subscribe request and creates a temporary handler with the correct ID.
    %IM.SubscribeResponse{
      subscription_id: 0,
      max_interval: req.max_interval
    }
  end

  @spec handle_read(module(), IM.ReadRequest.t(), map()) :: IM.ReportData.t()
  def handle_read(device, %IM.ReadRequest{} = req, context \\ %{auth_mode: :pase}) do
    trace_context = Map.take(context, [:auth_mode, :fabric_index, :node_id])

    Logger.info(
      "[DEBUG-home] read paths=#{inspect(req.attribute_paths)} events=#{inspect(req.event_requests)} filters=#{inspect(req.data_version_filters)} ctx=#{inspect(trace_context)}"
    )

    version_filter_set = build_version_filter_set(device, req.data_version_filters)

    reports =
      Enum.flat_map(req.attribute_paths, fn path ->
        expanded = expand_attribute_path(device, path)

        if expanded == [] and concrete_path?(path) do
          # Concrete path that resolved to nothing → return error status
          [read_one_attribute(device, path, context)]
        else
          # Expanded (or wildcard with no matches → silently omit)
          expanded
          |> Enum.reject(fn cp ->
            MapSet.member?(version_filter_set, {cp.endpoint, cp.cluster})
          end)
          |> Enum.map(fn cp -> read_one_attribute(device, cp, context) end)
        end
      end)

    event_reports = read_events(device, req.event_requests, req.event_filters)

    summary = summarize_reports(reports)
    Logger.info("[DEBUG-home] read result=#{inspect(summary)} events=#{length(event_reports)}")

    MatterEx.DebugTrace.record(%{
      op: :read,
      paths: req.attribute_paths,
      events: req.event_requests,
      filters: req.data_version_filters,
      context: trace_context,
      result: summary,
      detail: debug_read_details(reports),
      event_count: length(event_reports)
    })

    %IM.ReportData{attribute_reports: reports, event_reports: event_reports}
  end

  @doc """
  Return `%{{endpoint, cluster} => data_version}` for every cluster covered by
  the given attribute paths (wildcard-aware).

  One DataVersion read per covered cluster — much cheaper than reading every
  attribute value. Used to gate subscription polling: since every attribute
  change bumps its cluster's DataVersion, an unchanged version map means nothing
  the subscription covers has changed, so the full attribute read can be skipped.
  """
  @spec cluster_versions(module() | nil, [map()]) ::
          %{{non_neg_integer(), non_neg_integer()} => non_neg_integer()}
  def cluster_versions(nil, _paths), do: %{}

  def cluster_versions(device, paths) do
    paths
    |> Enum.flat_map(&covered_clusters(device, &1))
    |> Enum.uniq()
    |> Map.new(fn {ep, cl} = key ->
      gen_name = device.__process_name__(ep, device.__cluster_module__(ep, cl).cluster_name())
      {key, GenServer.call(gen_name, :read_data_version)}
    end)
  end

  @doc """
  Whether any of `attribute_paths` covers the given `{endpoint, cluster}`.

  Pure (no attribute reads) — used to route a push change notification to the
  subscriptions that care about the changed cluster.
  """
  @spec covers?(module() | nil, [map()], {non_neg_integer(), non_neg_integer()}) :: boolean()
  def covers?(nil, _paths, _target), do: false

  def covers?(device, paths, {_ep, _cl} = target) do
    Enum.any?(paths, fn path -> target in covered_clusters(device, path) end)
  end

  defp covered_clusters(device, path) do
    endpoints =
      case path[:endpoint] do
        nil -> MapSet.to_list(device.__endpoint_ids__())
        ep -> if MapSet.member?(device.__endpoint_ids__(), ep), do: [ep], else: []
      end

    for ep <- endpoints, cl <- expand_clusters(device, ep, path[:cluster]), do: {ep, cl}
  end

  defp read_one_attribute(device, path, context) do
    case resolve_attribute(device, path) do
      {:ok, gen_name, attr_name, attr_type, attr_def} ->
        target = {path[:endpoint], path[:cluster]}

        case check_acl(device, context, :view, target) do
          :allow ->
            case GenServer.call(gen_name, {:read_attribute, attr_name}) do
              {:ok, value} ->
                value =
                  path
                  |> maybe_session_scoped_attribute(attr_name, value, context)
                  |> maybe_filter_fabric_scoped(attr_def, context)

                data_version = GenServer.call(gen_name, :read_data_version)

                {:data,
                 %{
                   version: data_version,
                   path: path,
                   value: to_tlv(attr_type, value)
                 }}

              {:error, reason} ->
                {:status, error_status(path, reason)}
            end

          :deny ->
            {:status, error_status(path, :unsupported_access)}
        end

      {:error, reason} ->
        {:status, error_status(path, reason)}
    end
  end

  @spec handle_write(module(), IM.WriteRequest.t(), map()) :: IM.WriteResponse.t()
  defp handle_write(device, %IM.WriteRequest{} = req, context) do
    trace_context = Map.take(context, [:auth_mode, :fabric_index, :node_id])
    paths = Enum.map(req.write_requests, & &1.path)

    Logger.info("[DEBUG-home] write paths=#{inspect(paths)} ctx=#{inspect(trace_context)}")

    responses =
      Enum.map(req.write_requests, fn write ->
        case resolve_attribute(device, write.path) do
          {:ok, gen_name, attr_name, _attr_type, attr_def} ->
            target = {write.path[:endpoint], write.path[:cluster]}
            privilege = ACL.write_privilege(write.path[:cluster])

            case check_acl(device, context, privilege, target) do
              :allow ->
                value =
                  maybe_merge_fabric_scoped(gen_name, attr_name, write.value, attr_def, context)

                case GenServer.call(gen_name, {:write_attribute, attr_name, value}) do
                  :ok ->
                    %{path: write.path, status: Status.status_code(:success), cluster_status: nil}

                  {:error, reason} ->
                    error_status(write.path, reason)
                end

              :deny ->
                error_status(write.path, :unsupported_access)
            end

          {:error, reason} ->
            error_status(write.path, reason)
        end
      end)

    Logger.info("[DEBUG-home] write result=#{inspect(responses)}")

    MatterEx.DebugTrace.record(%{
      op: :write,
      paths: paths,
      context: trace_context,
      result: responses,
      detail: debug_write_details(req.write_requests)
    })

    %IM.WriteResponse{write_responses: responses}
  end

  @spec handle_invoke(module(), IM.InvokeRequest.t(), map()) :: IM.InvokeResponse.t()
  defp handle_invoke(device, %IM.InvokeRequest{} = req, context) do
    trace_context = Map.take(context, [:auth_mode, :fabric_index, :node_id])
    paths = Enum.map(req.invoke_requests, & &1.path)

    Logger.info("[DEBUG-home] invoke paths=#{inspect(paths)} ctx=#{inspect(trace_context)}")

    responses =
      Enum.map(req.invoke_requests, fn invoke ->
        case resolve_command(device, invoke.path) do
          {:ok, gen_name, cmd_name, cmd_def} ->
            target = {invoke.path[:endpoint], invoke.path[:cluster]}

            case check_acl(device, context, :operate, target) do
              :allow ->
                params = decode_command_params(invoke.fields, cmd_def)

                MatterEx.DebugTrace.record(%{
                  op: :invoke_params,
                  path: invoke.path,
                  raw_fields: invoke.fields,
                  decoded_params: Map.drop(params, [:_context]),
                  context: trace_context
                })

                case GenServer.call(gen_name, {:invoke_command, cmd_name, params, context}) do
                  {:ok, nil} ->
                    maybe_cleanup_remove_fabric(device, invoke.path, cmd_name, params, nil)

                    {:status,
                     %{
                       path: invoke.path,
                       status: Status.status_code(:success),
                       cluster_status: nil
                     }}

                  {:ok, response_fields} ->
                    maybe_cleanup_remove_fabric(
                      device,
                      invoke.path,
                      cmd_name,
                      params,
                      response_fields
                    )

                    response_path =
                      if cmd_def[:response_id] do
                        Map.put(invoke.path, :command, cmd_def.response_id)
                      else
                        invoke.path
                      end

                    {:command, %{path: response_path, fields: response_fields}}

                  {:error, reason} ->
                    {:status, command_error_status(invoke.path, reason)}
                end

              :deny ->
                {:status, command_error_status(invoke.path, :unsupported_access)}
            end

          {:error, reason} ->
            {:status, command_error_status(invoke.path, reason)}
        end
      end)

    summary = summarize_invokes(responses)
    Logger.info("[DEBUG-home] invoke result=#{inspect(summary)}")

    MatterEx.DebugTrace.record(%{
      op: :invoke,
      paths: paths,
      context: trace_context,
      result: summary,
      full_result: responses
    })

    %IM.InvokeResponse{invoke_responses: responses}
  end

  defp summarize_reports(reports) do
    Enum.map(reports, fn
      {:data, %{path: path, value: value}} -> {:data, path, elem(value, 0)}
      {:status, status} -> {:status, status}
      other -> other
    end)
  end

  defp summarize_invokes(responses) do
    Enum.map(responses, fn
      {:command, %{path: path}} -> {:command, path}
      {:status, status} -> {:status, status}
      other -> other
    end)
  end

  # ── DataVersionFilter ─────────────────────────────────────────

  defp build_version_filter_set(device, filters) do
    Enum.reduce(filters, MapSet.new(), fn filter, acc ->
      ep = filter.endpoint
      cl = filter.cluster

      case device.__cluster_module__(ep, cl) do
        nil ->
          acc

        _cluster_mod ->
          gen_name = device.__process_name__(ep, device.__cluster_module__(ep, cl).cluster_name())
          current_version = GenServer.call(gen_name, :read_data_version)

          if current_version == filter.data_version do
            MapSet.put(acc, {ep, cl})
          else
            acc
          end
      end
    end)
  end

  # ── Event reads ───────────────────────────────────────────────

  defp read_events(_device, [], _event_filters), do: []

  defp read_events(device, event_requests, event_filters) do
    event_store_name = device.__process_name__(0, :event_store)

    if event_store_name && Process.whereis(event_store_name) do
      event_min =
        case event_filters do
          [%{event_min: min} | _] -> min
          _ -> 0
        end

      events = EventStore.read(event_store_name, event_requests, event_min)

      Enum.map(events, fn e ->
        {:data,
         %{
           path: %{endpoint: e.endpoint, cluster: e.cluster, event: e.event},
           event_number: e.number,
           priority: e.priority,
           system_timestamp: e.system_timestamp,
           data: e.data
         }}
      end)
    else
      []
    end
  end

  # ── Wildcard expansion ────────────────────────────────────────

  defp concrete_path?(path) do
    Map.has_key?(path, :endpoint) and Map.has_key?(path, :cluster) and
      Map.has_key?(path, :attribute)
  end

  defp expand_attribute_path(device, path) do
    endpoints =
      case path[:endpoint] do
        nil -> MapSet.to_list(device.__endpoint_ids__())
        ep -> if MapSet.member?(device.__endpoint_ids__(), ep), do: [ep], else: []
      end

    for ep <- endpoints,
        cl <- expand_clusters(device, ep, path[:cluster]),
        attr <- expand_attributes(device, ep, cl, path[:attribute]) do
      %{endpoint: ep, cluster: cl, attribute: attr.id}
    end
  end

  defp expand_clusters(device, ep, nil), do: device.__cluster_ids__(ep)

  defp expand_clusters(device, ep, cluster_id) do
    if device.__cluster_module__(ep, cluster_id), do: [cluster_id], else: []
  end

  defp expand_attributes(device, ep, cluster_id, nil) do
    case device.__cluster_module__(ep, cluster_id) do
      nil -> []
      cluster_mod -> cluster_mod.attribute_defs()
    end
  end

  defp expand_attributes(device, ep, cluster_id, attr_id) do
    case device.__cluster_module__(ep, cluster_id) do
      nil ->
        []

      cluster_mod ->
        case Enum.find(cluster_mod.attribute_defs(), &(&1.id == attr_id)) do
          nil -> []
          attr -> [attr]
        end
    end
  end

  # ── Path resolution ────────────────────────────────────────────

  defp resolve_attribute(device, path) do
    endpoint_id = path[:endpoint]
    cluster_id = path[:cluster]
    attribute_id = path[:attribute]

    cond do
      endpoint_id == nil or not MapSet.member?(device.__endpoint_ids__(), endpoint_id) ->
        {:error, :unsupported_endpoint}

      cluster_id == nil or device.__cluster_module__(endpoint_id, cluster_id) == nil ->
        {:error, :unsupported_cluster}

      true ->
        cluster_mod = device.__cluster_module__(endpoint_id, cluster_id)
        gen_name = device.__process_name__(endpoint_id, cluster_mod.cluster_name())

        case find_attribute_by_id(cluster_mod, attribute_id) do
          nil -> {:error, :unsupported_attribute}
          attr -> {:ok, gen_name, attr.name, attr.type, attr}
        end
    end
  end

  defp resolve_command(device, path) do
    endpoint_id = path[:endpoint]
    cluster_id = path[:cluster]
    command_id = path[:command]

    cond do
      endpoint_id == nil or not MapSet.member?(device.__endpoint_ids__(), endpoint_id) ->
        {:error, :unsupported_endpoint}

      cluster_id == nil or device.__cluster_module__(endpoint_id, cluster_id) == nil ->
        {:error, :unsupported_cluster}

      true ->
        cluster_mod = device.__cluster_module__(endpoint_id, cluster_id)
        gen_name = device.__process_name__(endpoint_id, cluster_mod.cluster_name())

        case find_command_by_id(cluster_mod, command_id) do
          nil -> {:error, :unsupported_command}
          cmd -> {:ok, gen_name, cmd.name, cmd}
        end
    end
  end

  defp find_attribute_by_id(cluster_mod, attr_id) do
    Enum.find(cluster_mod.attribute_defs(), &(&1.id == attr_id))
  end

  defp find_command_by_id(cluster_mod, cmd_id) do
    Enum.find(cluster_mod.command_defs(), &(&1.id == cmd_id))
  end

  # ── Command param mapping ──────────────────────────────────────

  defp decode_command_params(nil, _cmd_def), do: %{}

  defp decode_command_params(fields, %{params: params}) when is_map(fields) do
    params
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{param_name, _type}, idx}, acc ->
      case Map.get(fields, idx) do
        nil -> acc
        value -> Map.put(acc, param_name, value)
      end
    end)
  end

  # ── TLV type conversion ───────────────────────────────────────

  defp to_tlv(:boolean, value), do: {:bool, value}
  defp to_tlv(:uint8, value), do: {:uint8, value}
  defp to_tlv(:uint16, value), do: {:uint16, value}
  defp to_tlv(:uint32, value), do: {:uint32, value}
  defp to_tlv(:uint64, value), do: {:uint64, value}
  defp to_tlv(:int8, value), do: {:int8, value}
  defp to_tlv(:int16, value), do: {:int16, value}
  defp to_tlv(:int32, value), do: {:int32, value}
  defp to_tlv(:int64, value), do: {:int64, value}
  defp to_tlv(:string, value), do: {:string, value}
  defp to_tlv(:bytes, value), do: {:bytes, value}
  defp to_tlv(:enum8, value), do: {:uint, value}
  defp to_tlv(:bitmap8, value), do: {:uint, value}
  defp to_tlv(:bitmap16, value), do: {:uint, value}
  defp to_tlv(:struct, value) when is_map(value), do: {:struct, value}

  defp to_tlv(:list, value) when is_list(value) do
    {:array, Enum.map(value, &to_tlv_dynamic/1)}
  end

  defp to_tlv(_type, value), do: {:uint, value}

  defp to_tlv_dynamic({type, _value} = tagged)
       when type in [
              :bool,
              :uint,
              :uint8,
              :uint16,
              :uint32,
              :uint64,
              :int,
              :int8,
              :int16,
              :int32,
              :int64,
              :string,
              :bytes,
              :array,
              :struct
            ],
       do: tagged

  defp to_tlv_dynamic(nil), do: :null
  defp to_tlv_dynamic(value) when is_boolean(value), do: {:bool, value}
  defp to_tlv_dynamic(value) when is_integer(value) and value >= 0, do: {:uint, value}
  defp to_tlv_dynamic(value) when is_integer(value), do: {:int, value}
  defp to_tlv_dynamic(value) when is_binary(value), do: {:bytes, value}
  defp to_tlv_dynamic(value) when is_list(value), do: {:array, Enum.map(value, &to_tlv_dynamic/1)}

  defp to_tlv_dynamic(value) when is_map(value) do
    {:struct, Map.new(value, fn {tag, field_value} -> {tag, to_tlv_dynamic(field_value)} end)}
  end

  defp to_tlv_dynamic(value), do: value

  # ── Error helpers ──────────────────────────────────────────────

  defp error_status(path, reason) do
    %{
      path: path,
      status: status_for(reason),
      cluster_status: nil
    }
  end

  defp command_error_status(path, reason) do
    %{
      path: path,
      status: status_for(reason),
      cluster_status: nil
    }
  end

  defp status_for(:unsupported_endpoint), do: Status.status_code(:unsupported_endpoint)
  defp status_for(:unsupported_cluster), do: Status.status_code(:unsupported_cluster)
  defp status_for(:unsupported_attribute), do: Status.status_code(:unsupported_attribute)
  defp status_for(:unsupported_command), do: Status.status_code(:unsupported_command)
  defp status_for(:unsupported_write), do: Status.status_code(:unsupported_write)
  defp status_for(:unsupported_access), do: Status.status_code(:unsupported_access)
  defp status_for(:constraint_error), do: Status.status_code(:constraint_error)
  defp status_for(_), do: Status.status_code(:failure)

  defp maybe_cleanup_remove_fabric(
         device,
         %{endpoint: 0, cluster: 0x003E},
         :remove_fabric,
         params,
         response_fields
       ) do
    status =
      case response_fields do
        %{0 => {:uint, status}} -> status
        %{0 => {_type, status}} when is_integer(status) -> status
        %{0 => status} when is_integer(status) -> status
        nil -> 0
        _ -> nil
      end

    fabric_index =
      case response_fields do
        %{1 => {:uint, index}} -> index
        %{1 => {_type, index}} when is_integer(index) -> index
        %{1 => index} when is_integer(index) -> index
        _ -> params[:fabric_index]
      end

    if status == 0 and is_integer(fabric_index) and fabric_index > 0 do
      cleanup_access_control_fabric(device, fabric_index)
    end
  end

  defp maybe_cleanup_remove_fabric(_device, _path, _cmd_name, _params, _response_fields), do: :ok

  defp cleanup_access_control_fabric(device, fabric_index) do
    gen_name = device.__process_name__(0, :access_control)

    if gen_name && Process.whereis(gen_name) do
      case GenServer.call(gen_name, {:read_attribute, :acl}) do
        {:ok, entries} when is_list(entries) ->
          entries = Enum.reject(entries, &(extract_fabric_index(&1) == fabric_index))
          GenServer.call(gen_name, {:write_attribute, :acl, entries})

        _ ->
          :ok
      end
    end
  end

  defp debug_read_details(reports) do
    reports
    |> Enum.flat_map(fn
      {:data, %{path: %{endpoint: 0, cluster: 0x003E, attribute: attr}, value: value}} ->
        [%{cluster: 0x003E, attribute: attr, value: debug_value(value)}]

      _ ->
        []
    end)
  end

  defp debug_write_details(write_requests) do
    write_requests
    |> Enum.flat_map(fn
      %{path: %{endpoint: 0, cluster: 0x001F, attribute: attr}, value: value} ->
        [%{cluster: 0x001F, attribute: attr, value: debug_value(value)}]

      _ ->
        []
    end)
  end

  defp debug_value({type, value}) when type in [:bytes, :octet_string] and is_binary(value) do
    {type, byte_size(value)}
  end

  defp debug_value({type, values}) when type in [:array, :list] and is_list(values) do
    {type, Enum.map(values, &debug_value/1)}
  end

  defp debug_value({:struct, value}) when is_map(value) do
    {:struct, debug_value(value)}
  end

  defp debug_value(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {key, debug_value(val)} end)
  end

  defp debug_value(value) when is_list(value), do: Enum.map(value, &debug_value/1)
  defp debug_value(value), do: value

  # ── Fabric-scoped attribute helpers ──────────────────────────────

  # Filter a fabric-scoped list to only entries matching the requester's fabric
  defp maybe_filter_fabric_scoped(value, %{fabric_scoped: true}, %{fabric_index: fi})
       when is_list(value) and fi > 0 do
    Enum.filter(value, fn entry ->
      entry_fi = extract_fabric_index(entry)
      entry_fi == fi
    end)
  end

  defp maybe_filter_fabric_scoped(value, _attr_def, _context), do: value

  defp maybe_session_scoped_attribute(
         %{endpoint: 0, cluster: 0x003E},
         :current_fabric_index,
         _value,
         %{auth_mode: :case, fabric_index: fi}
       )
       when is_integer(fi) and fi > 0,
       do: fi

  defp maybe_session_scoped_attribute(_path, _attr_name, value, _context), do: value

  # Extract fabric_index from an entry that may use atom key :fabric_index,
  # integer key 254 (Matter FabricIndex tag), or tagged value {:uint, n}
  defp extract_fabric_index(entry) when is_map(entry) do
    case entry[:fabric_index] || entry[254] do
      {:uint, n} -> n
      {_type, n} when is_integer(n) -> n
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp extract_fabric_index(_), do: nil

  # On write for fabric-scoped attributes: preserve other fabrics' entries,
  # replace this fabric's entries with the new value
  defp maybe_merge_fabric_scoped(gen_name, attr_name, new_entries, %{fabric_scoped: true}, %{
         fabric_index: fi
       })
       when is_list(new_entries) and fi > 0 do
    new_entries = Enum.map(new_entries, &put_fabric_index(&1, fi))

    case GenServer.call(gen_name, {:read_attribute, attr_name}) do
      {:ok, existing} when is_list(existing) ->
        other_fabric_entries =
          Enum.reject(existing, fn entry ->
            extract_fabric_index(entry) == fi
          end)

        other_fabric_entries ++ new_entries

      _ ->
        new_entries
    end
  end

  defp maybe_merge_fabric_scoped(_gen_name, _attr_name, value, _attr_def, _context), do: value

  defp put_fabric_index(entry, fabric_index) when is_map(entry) do
    cond do
      Map.has_key?(entry, :fabric_index) -> entry
      Map.has_key?(entry, 254) -> entry
      true -> Map.put(entry, 254, fabric_index)
    end
  end

  defp put_fabric_index(entry, _fabric_index), do: entry

  # ── ACL enforcement ─────────────────────────────────────────────

  defp check_acl(device, context, required_privilege, target) do
    acl_gen_name = device.__process_name__(0, :access_control)

    acl_entries =
      if acl_gen_name && Process.whereis(acl_gen_name) do
        case GenServer.call(acl_gen_name, {:read_attribute, :acl}) do
          {:ok, entries} when is_list(entries) -> entries
          _ -> []
        end
      else
        []
      end

    ACL.check(context, acl_entries, required_privilege, target)
  end
end
