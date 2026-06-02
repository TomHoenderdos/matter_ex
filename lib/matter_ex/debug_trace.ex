defmodule MatterEx.DebugTrace do
  @moduledoc false

  @name __MODULE__
  @max_events 1_000

  def record(event) do
    ensure_started()

    Agent.update(@name, fn events ->
      entry = {System.monotonic_time(:millisecond), event}
      [entry | events] |> Enum.take(@max_events)
    end)
  end

  def dump do
    ensure_started()

    Agent.get(@name, fn events -> Enum.reverse(events) end)
  end

  def clear do
    ensure_started()
    Agent.update(@name, fn _events -> [] end)
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        case Agent.start_link(fn -> [] end, name: @name) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
