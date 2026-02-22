defmodule MatterEx.Protocol.MRP do
  @moduledoc """
  Message Reliability Protocol — retransmission state and backoff.

  Pure struct with no GenServer. Timer scheduling is the caller's
  responsibility (use `Process.send_after` in a GenServer).

  ## Backoff formula (Matter spec section 4.11.8)

      timeout = base_interval * 1.1 * 1.6^attempt * (1 + jitter)

  where base_interval is 300ms (active) or 500ms (idle).
  Max transmissions = 5 (1 original + 4 retries).
  """

  # Matter spec MRP timing constants
  @active_interval_ms 300
  @idle_interval_ms 500
  @backoff_margin 1.1
  @backoff_base 1.6
  @backoff_jitter 0.25
  @max_transmissions 5
  @ack_timeout_ms 200

  @type pending :: %{
    message: binary(),
    attempt: non_neg_integer()
  }

  @type t :: %__MODULE__{
    mode: :active | :idle,
    pending: %{non_neg_integer() => pending()}
  }

  defstruct mode: :active,
            pending: %{}

  @doc "Create new MRP state."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{mode: Keyword.get(opts, :mode, :active)}
  end

  @doc """
  Record an outgoing reliable message. The caller should schedule
  the first retransmission timer using `backoff_ms/3` with attempt 0.
  """
  @spec record_send(t(), non_neg_integer(), binary()) :: t()
  def record_send(%__MODULE__{} = state, exchange_id, message) do
    entry = %{message: message, attempt: 0}
    %{state | pending: Map.put(state.pending, exchange_id, entry)}
  end

  @doc """
  Handle a retransmission timer firing.

  Returns:
  - `{:retransmit, message, new_state}` — resend the message
  - `{:give_up, new_state}` — max retransmissions reached
  - `{:already_acked, new_state}` — exchange already acknowledged
  """
  @spec on_timeout(t(), non_neg_integer(), non_neg_integer()) ::
          {:retransmit, binary(), t()}
          | {:give_up, t()}
          | {:already_acked, t()}
  def on_timeout(%__MODULE__{} = state, exchange_id, attempt) do
    case Map.get(state.pending, exchange_id) do
      nil ->
        {:already_acked, state}

      %{attempt: recorded} when recorded != attempt ->
        {:already_acked, state}

      %{message: _msg} when attempt + 1 >= @max_transmissions ->
        {:give_up, %{state | pending: Map.delete(state.pending, exchange_id)}}

      %{message: msg} ->
        updated = Map.update!(state.pending, exchange_id, &%{&1 | attempt: attempt + 1})
        {:retransmit, msg, %{state | pending: updated}}
    end
  end

  @doc """
  Record that an ACK was received for an exchange.
  """
  @spec on_ack(t(), non_neg_integer()) :: {:ok, t()} | {:error, :not_found}
  def on_ack(%__MODULE__{} = state, exchange_id) do
    if Map.has_key?(state.pending, exchange_id) do
      {:ok, %{state | pending: Map.delete(state.pending, exchange_id)}}
    else
      {:error, :not_found}
    end
  end

  @doc "Check if there is a pending retransmission for an exchange."
  @spec pending?(t(), non_neg_integer()) :: boolean()
  def pending?(%__MODULE__{} = state, exchange_id) do
    Map.has_key?(state.pending, exchange_id)
  end

  @doc """
  Compute retransmission timeout in milliseconds.

  Pass `deterministic: true` to remove jitter (for testing).
  """
  @spec backoff_ms(t(), non_neg_integer(), keyword()) :: non_neg_integer()
  def backoff_ms(%__MODULE__{mode: mode}, attempt, opts \\ []) do
    base = if mode == :active, do: @active_interval_ms, else: @idle_interval_ms

    jitter =
      if Keyword.get(opts, :deterministic, false) do
        0.0
      else
        :rand.uniform() * @backoff_jitter
      end

    trunc(base * @backoff_margin * :math.pow(@backoff_base, attempt) * (1.0 + jitter))
  end

  @doc "Timeout in ms before sending a standalone ACK."
  @spec ack_timeout_ms() :: non_neg_integer()
  def ack_timeout_ms, do: @ack_timeout_ms

  @doc "Maximum number of transmissions (initial + retries)."
  @spec max_transmissions() :: non_neg_integer()
  def max_transmissions, do: @max_transmissions
end
