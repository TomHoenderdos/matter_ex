defmodule Matterlix.Transport.BLE.MockAdapter do
  @moduledoc """
  Test adapter for BLE transport.

  Uses an Agent to track all calls. Tests inject events via `simulate_*`
  functions and inspect sent data via `sent_packets/1`.
  """

  @behaviour Matterlix.Transport.BLE.Adapter

  # ── Adapter Callbacks ──────────────────────────────────────────────

  @impl true
  def start(opts) do
    owner = Keyword.fetch!(opts, :owner)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          owner: owner,
          opts: opts,
          advertising: false,
          ad_data: nil,
          sent_packets: [],
          stopped: false
        }
      end)

    {:ok, agent}
  end

  @impl true
  def start_advertising(agent, ad_data) do
    Agent.update(agent, fn state ->
      %{state | advertising: true, ad_data: ad_data}
    end)

    :ok
  end

  @impl true
  def stop_advertising(agent) do
    Agent.update(agent, fn state -> %{state | advertising: false} end)
    :ok
  end

  @impl true
  def send_data(agent, _connection_ref, data) do
    Agent.update(agent, fn state ->
      %{state | sent_packets: state.sent_packets ++ [data]}
    end)

    :ok
  end

  @impl true
  def stop(agent) do
    Agent.update(agent, fn state -> %{state | stopped: true, advertising: false} end)
    :ok
  end

  # ── Test Helpers ───────────────────────────────────────────────────

  @doc "Simulate a BLE connection from a commissioner."
  def simulate_connect(agent, connection_ref \\ :mock_conn) do
    owner = Agent.get(agent, & &1.owner)
    send(owner, {:ble_connected, connection_ref})
    :ok
  end

  @doc "Simulate incoming BLE data (written to RX characteristic)."
  def simulate_data(agent, data, connection_ref \\ :mock_conn) do
    owner = Agent.get(agent, & &1.owner)
    send(owner, {:ble_data, connection_ref, data})
    :ok
  end

  @doc "Simulate a BLE disconnection."
  def simulate_disconnect(agent, connection_ref \\ :mock_conn) do
    owner = Agent.get(agent, & &1.owner)
    send(owner, {:ble_disconnected, connection_ref})
    :ok
  end

  @doc "Get all packets sent via the TX characteristic."
  def sent_packets(agent) do
    Agent.get(agent, & &1.sent_packets)
  end

  @doc "Get current advertising data (nil if not advertising)."
  def advertising_data(agent) do
    Agent.get(agent, fn state ->
      if state.advertising, do: state.ad_data, else: nil
    end)
  end

  @doc "Check if the adapter is currently advertising."
  def advertising?(agent) do
    Agent.get(agent, & &1.advertising)
  end

  @doc "Check if the adapter has been stopped."
  def stopped?(agent) do
    Agent.get(agent, & &1.stopped)
  end

  @doc "Get the opts passed to start/1."
  def start_opts(agent) do
    Agent.get(agent, & &1.opts)
  end
end
