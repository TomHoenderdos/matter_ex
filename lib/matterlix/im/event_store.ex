defmodule Matterlix.IM.EventStore do
  @moduledoc """
  In-memory ring buffer for Matter events.

  Each device gets one EventStore GenServer. Events have a monotonically
  increasing event number (global across all clusters) and a priority
  (debug/info/critical). When the buffer is full, lowest-priority events
  are evicted first.
  """

  use GenServer

  @max_events 64

  @type event :: %{
          number: non_neg_integer(),
          endpoint: non_neg_integer(),
          cluster: non_neg_integer(),
          event: non_neg_integer(),
          priority: non_neg_integer(),
          system_timestamp: integer(),
          data: map()
        }

  # ── Client API ──────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec emit(GenServer.name(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), map()) :: :ok
  def emit(name, endpoint, cluster_id, event_id, priority, data) do
    GenServer.call(name, {:emit, endpoint, cluster_id, event_id, priority, data})
  end

  @spec read(GenServer.name(), [map()], non_neg_integer()) :: [event()]
  def read(name, event_paths, event_min \\ 0) do
    GenServer.call(name, {:read, event_paths, event_min})
  end

  # ── Server callbacks ────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{events: [], next_number: 0}}
  end

  @impl true
  def handle_call({:emit, endpoint, cluster_id, event_id, priority, data}, _from, state) do
    event = %{
      number: state.next_number,
      endpoint: endpoint,
      cluster: cluster_id,
      event: event_id,
      priority: priority,
      system_timestamp: System.system_time(:microsecond),
      data: data
    }

    events = state.events ++ [event]
    events = evict_if_full(events)

    {:reply, :ok, %{state | events: events, next_number: state.next_number + 1}}
  end

  def handle_call({:read, event_paths, event_min}, _from, state) do
    results =
      state.events
      |> Enum.filter(fn e -> e.number >= event_min end)
      |> Enum.filter(fn e -> matches_any_path?(e, event_paths) end)

    {:reply, results, state}
  end

  # ── Private helpers ─────────────────────────────────────────

  defp matches_any_path?(_event, []), do: true

  defp matches_any_path?(event, paths) do
    Enum.any?(paths, fn path ->
      (path[:endpoint] == nil or path[:endpoint] == event.endpoint) and
        (path[:cluster] == nil or path[:cluster] == event.cluster) and
        (path[:event] == nil or path[:event] == event.event)
    end)
  end

  defp evict_if_full(events) when length(events) <= @max_events, do: events

  defp evict_if_full(events) do
    # Drop oldest lowest-priority event
    min_priority =
      events |> Enum.map(& &1.priority) |> Enum.min()

    idx =
      Enum.find_index(events, fn e -> e.priority == min_priority end)

    List.delete_at(events, idx)
  end
end
