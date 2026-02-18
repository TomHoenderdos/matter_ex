defmodule Matterlix.Protocol.Counter do
  @moduledoc """
  Message counter management and sliding-window replay protection.

  Each session has its own counter for outgoing messages and a
  per-peer sliding window for incoming replay detection. State is
  a plain struct — thread it through your session state.
  """

  import Bitwise

  @window_size 32
  @max_counter 0xFFFFFFFF

  @type t :: %__MODULE__{
    local_counter: non_neg_integer(),
    peer_windows: %{term() => {non_neg_integer(), non_neg_integer()}}
  }

  defstruct local_counter: 0,
            peer_windows: %{}

  @doc """
  Create new counter state with a random initial value.
  """
  @spec new() :: t()
  def new do
    initial = :binary.decode_unsigned(:crypto.strong_rand_bytes(4), :big)
    %__MODULE__{local_counter: initial}
  end

  @doc """
  Create counter state with a specific initial value (for testing).
  """
  @spec new(non_neg_integer()) :: t()
  def new(initial) when is_integer(initial) and initial >= 0 do
    %__MODULE__{local_counter: initial}
  end

  @doc """
  Get the next counter value and advance the counter.
  """
  @spec next(t()) :: {non_neg_integer(), t()}
  def next(%__MODULE__{local_counter: c} = state) do
    next_c = if c == @max_counter, do: 0, else: c + 1
    {c, %{state | local_counter: next_c}}
  end

  @doc """
  Check if an incoming message counter is valid (not a replay).

  `peer_id` is any term identifying the sender.

  Returns:
  - `{:ok, new_state}` — counter accepted, window updated
  - `{:error, :duplicate}` — counter already seen
  - `{:error, :too_old}` — counter too far behind the window
  """
  @spec check_and_update(t(), term(), non_neg_integer()) ::
          {:ok, t()} | {:error, :duplicate | :too_old}
  def check_and_update(%__MODULE__{peer_windows: windows} = state, peer_id, counter) do
    case Map.get(windows, peer_id) do
      nil ->
        new_windows = Map.put(windows, peer_id, {counter, 1})
        {:ok, %{state | peer_windows: new_windows}}

      {max, bitmap} ->
        check_window(state, peer_id, counter, max, bitmap)
    end
  end

  # ── Private ─────────────────────────────────────────────────────

  defp check_window(state, peer_id, counter, max, bitmap) do
    cond do
      counter > max ->
        shift = counter - max
        new_bitmap = (bitmap <<< shift) ||| 1
        new_windows = Map.put(state.peer_windows, peer_id, {counter, new_bitmap})
        {:ok, %{state | peer_windows: new_windows}}

      counter == max ->
        {:error, :duplicate}

      max - counter < @window_size ->
        pos = max - counter

        if (bitmap &&& (1 <<< pos)) != 0 do
          {:error, :duplicate}
        else
          new_bitmap = bitmap ||| (1 <<< pos)
          new_windows = Map.put(state.peer_windows, peer_id, {max, new_bitmap})
          {:ok, %{state | peer_windows: new_windows}}
        end

      true ->
        {:error, :too_old}
    end
  end
end
