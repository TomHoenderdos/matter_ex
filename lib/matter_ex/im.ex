defmodule MatterEx.IM do
  @moduledoc """
  Matter Interaction Model codec — encode/decode IM payloads.

  Decode takes an opcode atom (from `ProtocolID.opcode_name`) and the
  raw TLV binary from `ProtoHeader.payload`. Encode takes a message
  struct and returns TLV binary.

  Attribute/command values use tagged tuples for encoding (e.g.
  `{:uint, 42}`) and plain Elixir values after decoding.
  """

  alias MatterEx.TLV

  # ── Message Structs ────────────────────────────────────────────

  defmodule StatusResponse do
    @moduledoc false
    defstruct status: 0
  end

  defmodule TimedRequest do
    @moduledoc false
    defstruct timeout_ms: 0
  end

  defmodule ReadRequest do
    @moduledoc false
    defstruct attribute_paths: [],
              event_requests: [],
              event_filters: [],
              data_version_filters: [],
              fabric_filtered: true
  end

  defmodule ReportData do
    @moduledoc false
    defstruct subscription_id: nil,
              attribute_reports: [],
              event_reports: [],
              more_chunked_messages: false,
              suppress_response: false
  end

  defmodule WriteRequest do
    @moduledoc false
    defstruct write_requests: [],
              timed_request: false,
              suppress_response: false
  end

  defmodule WriteResponse do
    @moduledoc false
    defstruct write_responses: []
  end

  defmodule InvokeRequest do
    @moduledoc false
    defstruct invoke_requests: [],
              timed_request: false,
              suppress_response: false
  end

  defmodule InvokeResponse do
    @moduledoc false
    defstruct invoke_responses: []
  end

  defmodule SubscribeRequest do
    @moduledoc false
    defstruct attribute_paths: [],
              min_interval: 0,
              max_interval: 60,
              fabric_filtered: true,
              keep_subscriptions: true
  end

  defmodule SubscribeResponse do
    @moduledoc false
    defstruct subscription_id: 0, max_interval: 0
  end

  # ── Public API ─────────────────────────────────────────────────

  @doc """
  Chunk a ReportData into multiple messages, each with at most `max_reports`
  attribute reports. All chunks except the last have `more_chunked_messages: true`.
  """
  @spec chunk_report_data(%ReportData{}, pos_integer()) :: [%ReportData{}]
  def chunk_report_data(%ReportData{} = report, max_reports \\ 9) when max_reports > 0 do
    chunks = Enum.chunk_every(report.attribute_reports, max_reports)

    case chunks do
      [] ->
        [report]

      [_single] ->
        [report]

      _ ->
        {init, [last]} = Enum.split(chunks, -1)

        init_reports =
          Enum.map(init, fn chunk ->
            %ReportData{report | attribute_reports: chunk, more_chunked_messages: true}
          end)

        last_report = %ReportData{report | attribute_reports: last, more_chunked_messages: false}
        init_reports ++ [last_report]
    end
  end

  @spec decode(atom(), binary()) :: {:ok, struct()} | {:error, atom()}
  def decode(opcode, binary) do
    decoded = TLV.decode(binary)
    decode_message(opcode, decoded)
  rescue
    _ -> {:error, :invalid_tlv}
  end

  @spec encode(struct()) :: binary()
  def encode(%StatusResponse{} = msg), do: encode_status_response(msg)
  def encode(%TimedRequest{} = msg), do: encode_timed_request(msg)
  def encode(%ReadRequest{} = msg), do: encode_read_request(msg)
  def encode(%ReportData{} = msg), do: encode_report_data(msg)
  def encode(%WriteRequest{} = msg), do: encode_write_request(msg)
  def encode(%WriteResponse{} = msg), do: encode_write_response(msg)
  def encode(%InvokeRequest{} = msg), do: encode_invoke_request(msg)
  def encode(%InvokeResponse{} = msg), do: encode_invoke_response(msg)
  def encode(%SubscribeRequest{} = msg), do: encode_subscribe_request(msg)
  def encode(%SubscribeResponse{} = msg), do: encode_subscribe_response(msg)

  # ── Decode dispatch ────────────────────────────────────────────

  defp decode_message(:status_response, map) do
    {:ok, %StatusResponse{status: map[0]}}
  end

  defp decode_message(:timed_request, map) do
    {:ok, %TimedRequest{timeout_ms: map[0]}}
  end

  defp decode_message(:read_request, map) do
    paths = for p <- map[0] || [], do: decode_attribute_path(p)
    event_reqs = for e <- map[1] || [], do: decode_event_path(e)
    event_filters = for f <- map[2] || [], do: decode_event_filter(f)
    dv_filters = for f <- map[4] || [], do: decode_data_version_filter(f)

    {:ok, %ReadRequest{
      attribute_paths: paths,
      event_requests: event_reqs,
      event_filters: event_filters,
      data_version_filters: dv_filters,
      fabric_filtered: Map.get(map, 3, false)
    }}
  end

  defp decode_message(:report_data, map) do
    reports = for r <- map[1] || [], do: decode_attribute_report(r)
    event_reports = for r <- map[2] || [], do: decode_event_report(r)

    {:ok, %ReportData{
      subscription_id: map[0],
      attribute_reports: reports,
      event_reports: event_reports,
      more_chunked_messages: Map.get(map, 3, false),
      suppress_response: Map.get(map, 4, false)
    }}
  end

  defp decode_message(:write_request, map) do
    writes = for w <- map[2] || [], do: decode_attribute_data(w)

    {:ok, %WriteRequest{
      write_requests: writes,
      suppress_response: Map.get(map, 0, false),
      timed_request: Map.get(map, 1, false)
    }}
  end

  defp decode_message(:write_response, map) do
    responses = for r <- map[0] || [], do: decode_attribute_status(r)
    {:ok, %WriteResponse{write_responses: responses}}
  end

  defp decode_message(:invoke_request, map) do
    invokes = for i <- map[2] || [], do: decode_command_data(i)

    {:ok, %InvokeRequest{
      invoke_requests: invokes,
      suppress_response: Map.get(map, 0, false),
      timed_request: Map.get(map, 1, false)
    }}
  end

  defp decode_message(:invoke_response, map) do
    responses = for r <- map[1] || [], do: decode_invoke_response_ib(r)
    {:ok, %InvokeResponse{invoke_responses: responses}}
  end

  defp decode_message(:subscribe_request, map) do
    paths = for p <- map[3] || [], do: decode_attribute_path(p)

    {:ok, %SubscribeRequest{
      keep_subscriptions: Map.get(map, 0, true),
      min_interval: Map.get(map, 1, 0),
      max_interval: Map.get(map, 2, 60),
      attribute_paths: paths,
      fabric_filtered: Map.get(map, 7, true)
    }}
  end

  defp decode_message(:subscribe_response, map) do
    {:ok, %SubscribeResponse{
      subscription_id: map[0],
      max_interval: map[2]
    }}
  end

  defp decode_message(_, _), do: {:error, :unknown_opcode}

  # ── Path decoders ──────────────────────────────────────────────

  defp decode_attribute_path(map) do
    path = %{}
    path = if map[2], do: Map.put(path, :endpoint, map[2]), else: path
    path = if map[3], do: Map.put(path, :cluster, map[3]), else: path
    path = if map[4], do: Map.put(path, :attribute, map[4]), else: path
    path
  end

  defp decode_data_version_filter(map) do
    path = map[0] || %{}
    %{endpoint: path[1], cluster: path[2], data_version: map[1]}
  end

  defp decode_event_path(map) do
    path = %{}
    path = if map[1], do: Map.put(path, :endpoint, map[1]), else: path
    path = if map[2], do: Map.put(path, :cluster, map[2]), else: path
    path = if map[3], do: Map.put(path, :event, map[3]), else: path
    path = if map[4], do: Map.put(path, :is_urgent, map[4]), else: path
    path
  end

  defp decode_event_filter(map) do
    %{event_min: map[1] || 0}
  end

  defp decode_event_report(map) do
    cond do
      map[1] -> {:data, decode_event_data(map[1])}
      map[0] -> {:status, decode_event_status(map[0])}
    end
  end

  defp decode_event_data(map) do
    path = decode_event_path(map[0] || %{})

    %{
      path: path,
      event_number: map[1],
      priority: map[2],
      system_timestamp: map[4],
      data: map[7]
    }
  end

  defp decode_event_status(map) do
    path = decode_event_path(map[0] || %{})
    status_ib = map[1] || %{}

    %{
      path: path,
      status: status_ib[0],
      cluster_status: status_ib[1]
    }
  end

  defp decode_command_path(map) do
    path = %{}
    path = if map[0], do: Map.put(path, :endpoint, map[0]), else: path
    path = if map[1], do: Map.put(path, :cluster, map[1]), else: path
    path = if map[2], do: Map.put(path, :command, map[2]), else: path
    path
  end

  # ── IB decoders ────────────────────────────────────────────────

  defp decode_attribute_report(map) do
    cond do
      map[1] -> {:data, decode_attribute_data(map[1])}
      map[0] -> {:status, decode_attribute_status(map[0])}
    end
  end

  defp decode_attribute_data(map) do
    %{
      version: map[0],
      path: decode_attribute_path(map[1]),
      value: map[2]
    }
  end

  defp decode_attribute_status(map) do
    status_ib = map[1]

    %{
      path: decode_attribute_path(map[0]),
      status: status_ib[0],
      cluster_status: status_ib[1]
    }
  end

  defp decode_command_data(map) do
    %{
      path: decode_command_path(map[0]),
      fields: map[1]
    }
  end

  defp decode_invoke_response_ib(map) do
    cond do
      map[0] -> {:command, decode_command_data(map[0])}
      map[1] -> {:status, decode_command_status(map[1])}
    end
  end

  defp decode_command_status(map) do
    status_ib = map[1]

    %{
      path: decode_command_path(map[0]),
      status: status_ib[0],
      cluster_status: status_ib[1]
    }
  end

  # ── Encoders ───────────────────────────────────────────────────

  # Matter spec requires InteractionModelRevision (tag 0xFF) in all IM messages
  @im_revision {0xFF, {:uint, 11}}

  defp encode_status_response(%StatusResponse{status: s}) do
    TLV.encode(%{0 => {:uint, s}, elem(@im_revision, 0) => elem(@im_revision, 1)})
  end

  defp encode_timed_request(%TimedRequest{timeout_ms: t}) do
    TLV.encode(%{0 => {:uint, t}, 0xFF => {:uint, 11}})
  end

  defp encode_read_request(%ReadRequest{} = req) do
    map = %{3 => {:bool, req.fabric_filtered}, 0xFF => {:uint, 11}}

    map =
      if req.attribute_paths != [] do
        paths = Enum.map(req.attribute_paths, &{:list, encode_attribute_path(&1)})
        Map.put(map, 0, {:array, paths})
      else
        map
      end

    map =
      if req.event_requests != [] do
        events = Enum.map(req.event_requests, &{:list, encode_event_path(&1)})
        Map.put(map, 1, {:array, events})
      else
        map
      end

    map =
      if req.event_filters != [] do
        filters = Enum.map(req.event_filters, &{:struct, encode_event_filter(&1)})
        Map.put(map, 2, {:array, filters})
      else
        map
      end

    map =
      if req.data_version_filters != [] do
        filters = Enum.map(req.data_version_filters, &{:struct, encode_data_version_filter(&1)})
        Map.put(map, 4, {:array, filters})
      else
        map
      end

    TLV.encode(map)
  end

  defp encode_report_data(%ReportData{} = msg) do
    map = %{}
    map = if msg.subscription_id, do: Map.put(map, 0, {:uint, msg.subscription_id}), else: map

    map =
      if msg.attribute_reports != [] do
        reports = Enum.map(msg.attribute_reports, &{:struct, encode_attribute_report(&1)})
        Map.put(map, 1, {:array, reports})
      else
        map
      end

    map =
      if msg.event_reports != [] do
        reports = Enum.map(msg.event_reports, &{:struct, encode_event_report(&1)})
        Map.put(map, 2, {:array, reports})
      else
        map
      end

    map = if msg.more_chunked_messages, do: Map.put(map, 3, {:bool, true}), else: map
    map = if msg.suppress_response, do: Map.put(map, 4, {:bool, true}), else: map
    map = Map.put(map, 0xFF, {:uint, 11})
    TLV.encode(map)
  end

  defp encode_write_request(%WriteRequest{} = msg) do
    map = %{
      0 => {:bool, msg.suppress_response},
      1 => {:bool, msg.timed_request},
      0xFF => {:uint, 11}
    }

    map =
      if msg.write_requests != [] do
        writes = Enum.map(msg.write_requests, &{:struct, encode_attribute_data(&1)})
        Map.put(map, 2, {:array, writes})
      else
        map
      end

    TLV.encode(map)
  end

  defp encode_write_response(%WriteResponse{} = msg) do
    responses = Enum.map(msg.write_responses, &{:struct, encode_attribute_status(&1)})
    TLV.encode(%{0 => {:array, responses}, 0xFF => {:uint, 11}})
  end

  defp encode_invoke_request(%InvokeRequest{} = msg) do
    map = %{
      0 => {:bool, msg.suppress_response},
      1 => {:bool, msg.timed_request},
      0xFF => {:uint, 11}
    }

    map =
      if msg.invoke_requests != [] do
        invokes = Enum.map(msg.invoke_requests, &{:struct, encode_command_data(&1)})
        Map.put(map, 2, {:array, invokes})
      else
        map
      end

    TLV.encode(map)
  end

  defp encode_invoke_response(%InvokeResponse{} = msg) do
    responses = Enum.map(msg.invoke_responses, &{:struct, encode_invoke_response_ib(&1)})
    TLV.encode(%{0 => {:bool, false}, 1 => {:array, responses}, 0xFF => {:uint, 11}})
  end

  defp encode_subscribe_request(%SubscribeRequest{} = msg) do
    map = %{
      0 => {:bool, msg.keep_subscriptions},
      1 => {:uint, msg.min_interval},
      2 => {:uint, msg.max_interval},
      7 => {:bool, msg.fabric_filtered},
      0xFF => {:uint, 11}
    }

    map =
      if msg.attribute_paths != [] do
        paths = Enum.map(msg.attribute_paths, &{:list, encode_attribute_path(&1)})
        Map.put(map, 3, {:array, paths})
      else
        map
      end

    TLV.encode(map)
  end

  defp encode_subscribe_response(%SubscribeResponse{} = msg) do
    TLV.encode(%{
      0 => {:uint, msg.subscription_id},
      2 => {:uint, msg.max_interval},
      0xFF => {:uint, 11}
    })
  end

  # ── Path encoders ──────────────────────────────────────────────

  defp encode_attribute_path(path) do
    map = %{}
    map = if path[:endpoint], do: Map.put(map, 2, {:uint, path.endpoint}), else: map
    map = if path[:cluster], do: Map.put(map, 3, {:uint, path.cluster}), else: map
    map = if path[:attribute], do: Map.put(map, 4, {:uint, path.attribute}), else: map
    map
  end

  defp encode_data_version_filter(filter) do
    %{
      0 => {:list, %{1 => {:uint, filter.endpoint}, 2 => {:uint, filter.cluster}}},
      1 => {:uint, filter.data_version}
    }
  end

  defp encode_event_path(path) do
    map = %{}
    map = if path[:endpoint], do: Map.put(map, 1, {:uint, path.endpoint}), else: map
    map = if path[:cluster], do: Map.put(map, 2, {:uint, path.cluster}), else: map
    map = if path[:event], do: Map.put(map, 3, {:uint, path.event}), else: map
    map = if path[:is_urgent], do: Map.put(map, 4, {:bool, path.is_urgent}), else: map
    map
  end

  defp encode_event_filter(filter) do
    %{1 => {:uint, filter.event_min}}
  end

  defp encode_event_report({:data, data}) do
    %{1 => {:struct, encode_event_data(data)}}
  end

  defp encode_event_report({:status, status}) do
    status_ib = %{0 => {:uint, status.status}}

    status_ib =
      if status[:cluster_status],
        do: Map.put(status_ib, 1, {:uint, status.cluster_status}),
        else: status_ib

    %{
      0 => {:struct, %{
        0 => {:list, encode_event_path(status.path)},
        1 => {:struct, status_ib}
      }}
    }
  end

  defp encode_event_data(data) do
    map = %{
      0 => {:list, encode_event_path(data.path)},
      1 => {:uint, data.event_number},
      2 => {:uint, data.priority}
    }

    map = if data[:system_timestamp], do: Map.put(map, 4, {:uint, data.system_timestamp}), else: map
    map = if data[:data], do: Map.put(map, 7, {:struct, data.data}), else: map
    map
  end

  defp encode_command_path(path) do
    map = %{}
    map = if path[:endpoint], do: Map.put(map, 0, {:uint, path.endpoint}), else: map
    map = if path[:cluster], do: Map.put(map, 1, {:uint, path.cluster}), else: map
    map = if path[:command], do: Map.put(map, 2, {:uint, path.command}), else: map
    map
  end

  # ── IB encoders ────────────────────────────────────────────────

  defp encode_attribute_report({:data, data}) do
    %{1 => {:struct, encode_attribute_data(data)}}
  end

  defp encode_attribute_report({:status, status}) do
    %{0 => {:struct, encode_attribute_status(status)}}
  end

  defp encode_attribute_data(data) do
    %{
      0 => {:uint, data.version},
      1 => {:list, encode_attribute_path(data.path)},
      2 => data.value
    }
  end

  defp encode_attribute_status(status) do
    status_ib = %{0 => {:uint, status.status}}

    status_ib =
      if status[:cluster_status],
        do: Map.put(status_ib, 1, {:uint, status.cluster_status}),
        else: status_ib

    %{
      0 => {:list, encode_attribute_path(status.path)},
      1 => {:struct, status_ib}
    }
  end

  defp encode_command_data(data) do
    map = %{0 => {:list, encode_command_path(data.path)}}
    map = if data[:fields], do: Map.put(map, 1, {:struct, data.fields}), else: map
    map
  end

  defp encode_invoke_response_ib({:command, data}) do
    %{0 => {:struct, encode_command_data(data)}}
  end

  defp encode_invoke_response_ib({:status, status}) do
    %{1 => {:struct, encode_command_status(status)}}
  end

  defp encode_command_status(status) do
    status_ib = %{0 => {:uint, status.status}}

    status_ib =
      if status[:cluster_status],
        do: Map.put(status_ib, 1, {:uint, status.cluster_status}),
        else: status_ib

    %{
      0 => {:list, encode_command_path(status.path)},
      1 => {:struct, status_ib}
    }
  end
end
