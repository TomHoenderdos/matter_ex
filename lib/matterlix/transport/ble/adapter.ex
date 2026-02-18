defmodule Matterlix.Transport.BLE.Adapter do
  @moduledoc """
  Behaviour for BLE hardware adapters.

  Separates the BTP + GenServer logic from hardware-specific BLE details.
  Implement this to plug in blue_heron, a raw HCI driver, or a test mock.

  The adapter sends events to the owner process (the BLE GenServer):

      {:ble_connected, connection_ref}
      {:ble_data, connection_ref, binary}
      {:ble_disconnected, connection_ref}
  """

  @doc """
  Start the adapter. Returns an opaque handle for subsequent calls.

  `opts` contains at minimum:
  - `:owner` — pid to receive BLE events
  - `:discriminator` — 12-bit commissioning discriminator
  - `:vendor_id` — 16-bit vendor ID
  - `:product_id` — 16-bit product ID
  """
  @callback start(opts :: keyword()) :: {:ok, handle :: term()} | {:error, term()}

  @doc "Begin BLE advertising with the CHIPoBLE service."
  @callback start_advertising(handle :: term(), ad_data :: binary()) :: :ok | {:error, term()}

  @doc "Stop advertising."
  @callback stop_advertising(handle :: term()) :: :ok

  @doc """
  Send data to the connected peer via the TX characteristic indication.

  `connection_ref` is the opaque reference from the `{:ble_connected, ref}` event.
  """
  @callback send_data(handle :: term(), connection_ref :: term(), data :: binary()) ::
              :ok | {:error, term()}

  @doc "Disconnect and clean up."
  @callback stop(handle :: term()) :: :ok
end
