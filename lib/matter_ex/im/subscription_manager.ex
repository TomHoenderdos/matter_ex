defmodule MatterEx.IM.SubscriptionManager do
  @moduledoc """
  Tracks active Matter subscriptions for a session.

  Pure functional module — caller threads state through.

  Each subscription monitors a set of attribute paths with min/max
  reporting intervals. The `due_reports/2` function checks which
  subscriptions need a periodic report based on elapsed time.

  ## Example

      mgr = SubscriptionManager.new()

      {sub_id, mgr} = SubscriptionManager.subscribe(mgr,
        [%{endpoint: 1, cluster: 6, attribute: 0}],
        0,   # min_interval (seconds)
        60   # max_interval (seconds)
      )

      # Later, check for due reports
      due = SubscriptionManager.due_reports(mgr, System.monotonic_time(:second))
  """

  @type subscription :: %{
          id: non_neg_integer(),
          paths: [map()],
          min_interval: non_neg_integer(),
          max_interval: non_neg_integer(),
          last_report_at: integer(),
          last_sent_at: integer() | nil,
          last_values: map(),
          last_versions: map()
        }

  @type t :: %__MODULE__{
          subscriptions: %{non_neg_integer() => subscription()},
          next_id: non_neg_integer()
        }

  defstruct subscriptions: %{},
            next_id: 1

  @doc """
  Create a new empty SubscriptionManager.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Register a subscription for the given attribute paths.

  Returns `{subscription_id, updated_state}`.
  """
  @spec subscribe(t(), [map()], non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), t()}
  def subscribe(%__MODULE__{} = state, paths, min_interval, max_interval) do
    sub_id = state.next_id
    now = System.monotonic_time(:second)

    subscription = %{
      id: sub_id,
      paths: paths,
      min_interval: min_interval,
      max_interval: max_interval,
      last_report_at: now,
      last_sent_at: nil,
      last_values: %{},
      last_versions: %{}
    }

    subscriptions = Map.put(state.subscriptions, sub_id, subscription)

    {sub_id, %{state | subscriptions: subscriptions, next_id: sub_id + 1}}
  end

  @doc """
  Remove a subscription by ID.
  """
  @spec unsubscribe(t(), non_neg_integer()) :: t()
  def unsubscribe(%__MODULE__{} = state, sub_id) do
    %{state | subscriptions: Map.delete(state.subscriptions, sub_id)}
  end

  @doc """
  List all active subscriptions.
  """
  @spec subscriptions(t()) :: [subscription()]
  def subscriptions(%__MODULE__{} = state) do
    Map.values(state.subscriptions)
  end

  @doc """
  Check which subscriptions are due for a report check.

  Returns `{sub_id, paths}` for each subscription whose min-interval change-check
  cadence has elapsed (measured from `last_report_at`) or whose max-interval
  report is due (measured from the last *sent* report). The caller decides
  whether to actually send after comparing values.
  """
  @spec due_reports(t(), integer()) :: [{non_neg_integer(), [map()]}]
  def due_reports(%__MODULE__{} = state, now) do
    Enum.flat_map(state.subscriptions, fn {sub_id, sub} ->
      elapsed = now - sub.last_report_at
      check_interval = max(sub.min_interval, 1)

      if elapsed >= check_interval or heartbeat_due?(sub, now) do
        [{sub_id, sub.paths}]
      else
        []
      end
    end)
  end

  @doc """
  Check whether a subscription is due for a report on its `max_interval`.

  Returns `true` when a report was previously sent (`last_sent_at` set) and at
  least 80% of `max_interval` has elapsed since. Anchored on the last *sent*
  report, not the last poll. The report fires at 80% of the negotiated interval
  (rather than 100%) to defensively leave headroom for poll granularity, network
  delay, and retransmits, so the subscriber always hears back in plenty of time.

  A `max_interval` of 0 disables it; it is only used in tests as an "always due"
  value, and real subscriptions negotiate a positive ceiling.
  """
  @spec max_interval_elapsed?(t(), non_neg_integer(), integer()) :: boolean()
  def max_interval_elapsed?(%__MODULE__{} = state, sub_id, now) do
    case Map.get(state.subscriptions, sub_id) do
      nil -> false
      sub -> heartbeat_due?(sub, now)
    end
  end

  # Report at 80% of max_interval rather than on it: the subscriber SHALL tear the
  # subscription down if no report arrives within max_interval (Core spec §8.5),
  # so the margin absorbs poll granularity and MRP retransmits.
  #
  # Never earlier than min_interval, though — "Each Report transaction SHALL NOT be
  # initiated by the publisher until the minimum interval has expired since the
  # last Report transaction in the subscription" (§8.5). At 100% that floor held
  # implicitly, because the negotiated max_interval is clamped to at least
  # min_interval. At 80% it doesn't: `min_interval: 50, max_interval: 60` is a
  # legal negotiation whose 80% mark lands 2s inside the floor.
  defp heartbeat_due?(
         %{last_sent_at: sent, max_interval: max_interval, min_interval: min_interval},
         now
       )
       when is_integer(sent) and max_interval > 0,
       do: now - sent >= max(div(max_interval * 4, 5), min_interval)

  defp heartbeat_due?(_sub, _now), do: false

  @doc """
  Check if a subscription is throttled by `min_interval`.

  Returns `true` when the time since the last sent report is less than
  `min_interval`, meaning a change-triggered report should be suppressed.
  """
  @spec throttled?(t(), non_neg_integer(), integer()) :: boolean()
  def throttled?(%__MODULE__{} = state, sub_id, now) do
    case Map.get(state.subscriptions, sub_id) do
      nil -> false
      %{min_interval: 0} -> false
      %{last_sent_at: nil} -> false
      sub -> now - sub.last_sent_at < sub.min_interval
    end
  end

  @doc """
  Record that a report was checked for a subscription.

  Updates `last_report_at`, `last_values`, and the per-cluster `last_versions`
  used to gate polling. Does NOT update `last_sent_at` — use `record_sent/5`.
  """
  @spec record_report(t(), non_neg_integer(), map(), integer(), map()) :: t()
  def record_report(%__MODULE__{} = state, sub_id, values, now, versions \\ %{}) do
    case Map.get(state.subscriptions, sub_id) do
      nil ->
        state

      sub ->
        sub = %{sub | last_report_at: now, last_values: values, last_versions: versions}
        %{state | subscriptions: Map.put(state.subscriptions, sub_id, sub)}
    end
  end

  @doc """
  Record that a report was actually sent for a subscription.

  Updates `last_sent_at`, `last_report_at`, `last_values`, and `last_versions`.
  """
  @spec record_sent(t(), non_neg_integer(), map(), integer(), map()) :: t()
  def record_sent(%__MODULE__{} = state, sub_id, values, now, versions \\ %{}) do
    case Map.get(state.subscriptions, sub_id) do
      nil ->
        state

      sub ->
        sub = %{
          sub
          | last_sent_at: now,
            last_report_at: now,
            last_values: values,
            last_versions: versions
        }

        %{state | subscriptions: Map.put(state.subscriptions, sub_id, sub)}
    end
  end

  @doc """
  Get a subscription by ID.
  """
  @spec get(t(), non_neg_integer()) :: subscription() | nil
  def get(%__MODULE__{} = state, sub_id) do
    Map.get(state.subscriptions, sub_id)
  end

  @doc """
  Check if any subscriptions are active.
  """
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{} = state) do
    map_size(state.subscriptions) > 0
  end

  @doc """
  Remove all subscriptions. Used for session cleanup.
  """
  @spec unsubscribe_all(t()) :: t()
  def unsubscribe_all(%__MODULE__{} = state) do
    %{state | subscriptions: %{}}
  end
end
