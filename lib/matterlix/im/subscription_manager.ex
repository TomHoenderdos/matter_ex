defmodule Matterlix.IM.SubscriptionManager do
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
    last_values: map()
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
      last_values: %{}
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
  Check which subscriptions are due for a periodic report.

  Returns a list of `{sub_id, paths}` tuples for subscriptions whose
  `max_interval` has elapsed since the last report.
  """
  @spec due_reports(t(), integer()) :: [{non_neg_integer(), [map()]}]
  def due_reports(%__MODULE__{} = state, now) do
    Enum.flat_map(state.subscriptions, fn {sub_id, sub} ->
      elapsed = now - sub.last_report_at

      if elapsed >= sub.max_interval do
        [{sub_id, sub.paths}]
      else
        []
      end
    end)
  end

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

  Updates `last_report_at` and `last_values` for change detection.
  Does NOT update `last_sent_at` — use `record_sent/3` for that.
  """
  @spec record_report(t(), non_neg_integer(), map(), integer()) :: t()
  def record_report(%__MODULE__{} = state, sub_id, values, now) do
    case Map.get(state.subscriptions, sub_id) do
      nil ->
        state

      sub ->
        sub = %{sub | last_report_at: now, last_values: values}
        %{state | subscriptions: Map.put(state.subscriptions, sub_id, sub)}
    end
  end

  @doc """
  Record that a report was actually sent for a subscription.

  Updates `last_sent_at`, `last_report_at`, and `last_values`.
  """
  @spec record_sent(t(), non_neg_integer(), map(), integer()) :: t()
  def record_sent(%__MODULE__{} = state, sub_id, values, now) do
    case Map.get(state.subscriptions, sub_id) do
      nil ->
        state

      sub ->
        sub = %{sub | last_sent_at: now, last_report_at: now, last_values: values}
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
