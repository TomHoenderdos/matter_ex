defmodule Matterlix.IM.Router do
  @moduledoc """
  Routes IM messages to cluster GenServers.

  Bridges the IM codec layer (Phase 5) to the cluster runtime (Phase 6).
  All functions are pure — the router itself has no state.
  """

  alias Matterlix.{ACL, IM}
  alias Matterlix.IM.{EventStore, Status}

  @doc """
  Dispatch an IM message to the appropriate cluster(s) and return the response.

  The optional `context` parameter carries session identity for ACL enforcement.
  Defaults to PASE context (implicit admin, bypasses ACL).
  """
  @spec handle(module(), atom(), struct(), map()) :: struct()
  def handle(device, opcode, request, context \\ %{auth_mode: :pase})

  def handle(device, :read_request, %IM.ReadRequest{} = req, context), do: handle_read(device, req, context)
  def handle(device, :write_request, %IM.WriteRequest{} = req, context), do: handle_write(device, req, context)
  def handle(device, :invoke_request, %IM.InvokeRequest{} = req, context), do: handle_invoke(device, req, context)

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
          |> Enum.reject(fn cp -> MapSet.member?(version_filter_set, {cp.endpoint, cp.cluster}) end)
          |> Enum.map(fn cp -> read_one_attribute(device, cp, context) end)
        end
      end)

    event_reports = read_events(device, req.event_requests, req.event_filters)

    %IM.ReportData{attribute_reports: reports, event_reports: event_reports}
  end

  defp read_one_attribute(device, path, context) do
    case resolve_attribute(device, path) do
      {:ok, gen_name, attr_name, attr_type, attr_def} ->
        target = {path[:endpoint], path[:cluster]}

        case check_acl(device, context, :view, target) do
          :allow ->
            case GenServer.call(gen_name, {:read_attribute, attr_name}) do
              {:ok, value} ->
                value = maybe_filter_fabric_scoped(value, attr_def, context)
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
    responses =
      Enum.map(req.write_requests, fn write ->
        case resolve_attribute(device, write.path) do
          {:ok, gen_name, attr_name, _attr_type, attr_def} ->
            target = {write.path[:endpoint], write.path[:cluster]}
            privilege = ACL.write_privilege(write.path[:cluster])

            case check_acl(device, context, privilege, target) do
              :allow ->
                value = maybe_merge_fabric_scoped(gen_name, attr_name, write.value, attr_def, context)

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

    %IM.WriteResponse{write_responses: responses}
  end

  @spec handle_invoke(module(), IM.InvokeRequest.t(), map()) :: IM.InvokeResponse.t()
  defp handle_invoke(device, %IM.InvokeRequest{} = req, context) do
    responses =
      Enum.map(req.invoke_requests, fn invoke ->
        case resolve_command(device, invoke.path) do
          {:ok, gen_name, cmd_name, cmd_def} ->
            target = {invoke.path[:endpoint], invoke.path[:cluster]}

            case check_acl(device, context, :operate, target) do
              :allow ->
                params = decode_command_params(invoke.fields, cmd_def)

                case GenServer.call(gen_name, {:invoke_command, cmd_name, params}) do
                  {:ok, nil} ->
                    {:status,
                     %{
                       path: invoke.path,
                       status: Status.status_code(:success),
                       cluster_status: nil
                     }}

                  {:ok, response_fields} ->
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

    %IM.InvokeResponse{invoke_responses: responses}
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
    Map.has_key?(path, :endpoint) and Map.has_key?(path, :cluster) and Map.has_key?(path, :attribute)
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
  defp to_tlv(:uint8, value), do: {:uint, value}
  defp to_tlv(:uint16, value), do: {:uint, value}
  defp to_tlv(:uint32, value), do: {:uint, value}
  defp to_tlv(:uint64, value), do: {:uint, value}
  defp to_tlv(:int8, value), do: {:int, value}
  defp to_tlv(:int16, value), do: {:int, value}
  defp to_tlv(:int32, value), do: {:int, value}
  defp to_tlv(:string, value), do: {:string, value}
  defp to_tlv(:bytes, value), do: {:bytes, value}
  defp to_tlv(:enum8, value), do: {:uint, value}
  defp to_tlv(:bitmap8, value), do: {:uint, value}
  defp to_tlv(:bitmap16, value), do: {:uint, value}
  defp to_tlv(:struct, value) when is_map(value), do: {:struct, value}
  defp to_tlv(:list, value), do: {:array, Enum.map(value, &{:uint, &1})}
  defp to_tlv(_type, value), do: {:uint, value}

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
  defp status_for(_), do: Status.status_code(:failure)

  # ── Fabric-scoped attribute helpers ──────────────────────────────

  # Filter a fabric-scoped list to only entries matching the requester's fabric
  defp maybe_filter_fabric_scoped(value, %{fabric_scoped: true}, %{fabric_index: fi})
       when is_list(value) and fi > 0 do
    Enum.filter(value, fn entry ->
      entry_fi = entry[:fabric_index] || entry["fabric_index"]
      entry_fi == fi
    end)
  end

  defp maybe_filter_fabric_scoped(value, _attr_def, _context), do: value

  # On write for fabric-scoped attributes: preserve other fabrics' entries,
  # replace this fabric's entries with the new value
  defp maybe_merge_fabric_scoped(gen_name, attr_name, new_entries, %{fabric_scoped: true}, %{fabric_index: fi})
       when is_list(new_entries) and fi > 0 do
    case GenServer.call(gen_name, {:read_attribute, attr_name}) do
      {:ok, existing} when is_list(existing) ->
        other_fabric_entries = Enum.reject(existing, fn entry ->
          (entry[:fabric_index] || entry["fabric_index"]) == fi
        end)

        other_fabric_entries ++ new_entries

      _ ->
        new_entries
    end
  end

  defp maybe_merge_fabric_scoped(_gen_name, _attr_name, value, _attr_def, _context), do: value

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
