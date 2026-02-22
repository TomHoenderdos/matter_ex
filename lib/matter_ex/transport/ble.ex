defmodule MatterEx.Transport.BLE do
  @moduledoc """
  CHIPoBLE transport GenServer.

  Manages the BLE connection lifecycle for Matter commissioning. Delegates
  fragmentation/reassembly to `MatterEx.Transport.BTP`. Communicates with
  upper layers via messages:

      {:ble_connected, transport_pid}
      {:ble_data, transport_pid, complete_message}
      {:ble_disconnected, transport_pid}

  Hardware access is delegated to a configured adapter module implementing
  `MatterEx.Transport.BLE.Adapter`.

  ## Example

      {:ok, ble} = MatterEx.Transport.BLE.start_link(
        discriminator: 3840,
        vendor_id: 0xFFF1,
        product_id: 0x8001,
        adapter: SomeAdapter
      )

      # Adapter sends events, GenServer relays to owner
      # Send data back (BTP-fragmented automatically):
      MatterEx.Transport.BLE.send(ble, response_data)
  """

  use GenServer

  alias MatterEx.Transport.BTP

  # CHIPoBLE GATT Service
  @gatt_service_uuid 0xFFF6
  @tx_characteristic "18EE2EF5-263D-4559-959F-4F9C429F9D11"
  @rx_characteristic "18EE2EF5-263D-4559-959F-4F9C429F9D12"
  @additional_data_uuid "64630238-8772-45F2-B87D-748A83218F04"

  defmodule State do
    @moduledoc false
    defstruct [
      :adapter,
      :adapter_handle,
      :connection_ref,
      :owner,
      :discriminator,
      :vendor_id,
      :product_id,
      btp: nil,
      phase: :idle
    ]
  end

  # ── GATT Constants ─────────────────────────────────────────────────

  def gatt_service_uuid, do: @gatt_service_uuid
  def tx_characteristic_uuid, do: @tx_characteristic
  def rx_characteristic_uuid, do: @rx_characteristic
  def additional_data_uuid, do: @additional_data_uuid

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Start the BLE transport.

  Required options:
  - `:discriminator` — 12-bit commissioning discriminator (0..4095)
  - `:vendor_id` — 16-bit vendor ID
  - `:product_id` — 16-bit product ID
  - `:adapter` — module implementing `MatterEx.Transport.BLE.Adapter`

  Optional:
  - `:owner` — pid to receive events (default: calling process)
  - `:name` — GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Send data over the BLE connection. Data is BTP-fragmented automatically.
  """
  @spec send(GenServer.server(), binary()) :: :ok | {:error, atom()}
  def send(server, data) when is_binary(data) do
    GenServer.call(server, {:send, data})
  end

  @doc """
  Stop BLE advertising.
  """
  @spec stop_advertising(GenServer.server()) :: :ok
  def stop_advertising(server) do
    GenServer.call(server, :stop_advertising)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────

  @impl true
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    owner = Keyword.get(opts, :owner, self())
    discriminator = Keyword.fetch!(opts, :discriminator)
    vendor_id = Keyword.fetch!(opts, :vendor_id)
    product_id = Keyword.fetch!(opts, :product_id)

    adapter_opts = [
      owner: self(),
      discriminator: discriminator,
      vendor_id: vendor_id,
      product_id: product_id
    ]

    case adapter.start(adapter_opts) do
      {:ok, handle} ->
        ad_data = build_ad_data(discriminator, vendor_id, product_id)
        adapter.start_advertising(handle, ad_data)

        state = %State{
          adapter: adapter,
          adapter_handle: handle,
          owner: owner,
          discriminator: discriminator,
          vendor_id: vendor_id,
          product_id: product_id,
          btp: BTP.new(),
          phase: :idle
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, data}, _from, %{phase: :connected} = state) do
    {packets, new_btp} = BTP.fragment(state.btp, data)

    Enum.each(packets, fn packet ->
      state.adapter.send_data(state.adapter_handle, state.connection_ref, packet)
    end)

    {:reply, :ok, %{state | btp: new_btp}}
  end

  def handle_call({:send, _data}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:stop_advertising, _from, state) do
    state.adapter.stop_advertising(state.adapter_handle)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:ble_connected, connection_ref}, state) do
    new_state = %{state |
      connection_ref: connection_ref,
      phase: :handshaking,
      btp: BTP.new()
    }

    Kernel.send(state.owner, {:ble_connected, self()})
    {:noreply, new_state}
  end

  def handle_info({:ble_data, _ref, data}, %{phase: :handshaking} = state) do
    case BTP.decode_handshake(data) do
      {:request, params} ->
        # Respond with handshake response, negotiating MTU and window size
        mtu = min(params.mtu, state.btp.mtu)
        window_size = min(params.window_size, state.btp.window_size)
        response = BTP.handshake_response(4, mtu: mtu, window_size: window_size)

        state.adapter.send_data(state.adapter_handle, state.connection_ref, response)

        new_btp = %{state.btp | mtu: mtu, window_size: window_size}
        {:noreply, %{state | phase: :connected, btp: new_btp}}

      _ ->
        # Unexpected data during handshake — ignore
        {:noreply, state}
    end
  end

  def handle_info({:ble_data, _ref, data}, %{phase: :connected} = state) do
    case BTP.receive_segment(state.btp, data) do
      {:ok, new_btp} ->
        {:noreply, %{state | btp: new_btp}}

      {:complete, message, new_btp} ->
        Kernel.send(state.owner, {:ble_data, self(), message})
        {:noreply, %{state | btp: new_btp}}

      {:ack_only, _ack_num, new_btp} ->
        {:noreply, %{state | btp: new_btp}}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info({:ble_data, _ref, _data}, state) do
    # Data in idle state — ignore
    {:noreply, state}
  end

  def handle_info({:ble_disconnected, _ref}, state) do
    Kernel.send(state.owner, {:ble_disconnected, self()})

    {:noreply, %{state |
      connection_ref: nil,
      phase: :idle,
      btp: BTP.new(mtu: state.btp.mtu, window_size: state.btp.window_size)
    }}
  end

  @impl true
  def terminate(_reason, state) do
    if state.adapter_handle do
      state.adapter.stop(state.adapter_handle)
    end

    :ok
  end

  # ── Private ────────────────────────────────────────────────────────

  defp build_ad_data(discriminator, vendor_id, product_id) do
    <<discriminator::little-16, vendor_id::little-16, product_id::little-16>>
  end
end
