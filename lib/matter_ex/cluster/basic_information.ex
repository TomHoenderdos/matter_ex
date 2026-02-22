defmodule MatterEx.Cluster.BasicInformation do
  @moduledoc """
  Matter Basic Information cluster (0x0028).

  Required on endpoint 0. Provides device metadata.
  Populated at init time with device options.
  """

  use MatterEx.Cluster, id: 0x0028, name: :basic_information

  attribute 0x0001, :vendor_name, :string, default: ""
  attribute 0x0002, :vendor_id, :uint16, default: 0
  attribute 0x0003, :product_name, :string, default: ""
  attribute 0x0004, :product_id, :uint16, default: 0
  attribute 0x0005, :node_label, :string, default: "", writable: true
  attribute 0x0007, :hardware_version, :uint16, default: 0
  attribute 0x0008, :hardware_version_string, :string, default: "1.0"
  attribute 0x0009, :software_version, :uint32, default: 1
  attribute 0x000A, :software_version_string, :string, default: "1.0.0"
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  event 0x00, :start_up, :critical
  event 0x01, :shut_down, :critical

  @impl true
  def init(opts) do
    {:ok, state} = super(opts)

    # Emit StartUp event with software_version
    sw_version = Map.get(state, :software_version, 1)
    event_store = Keyword.get(opts, :event_store)

    if event_store && Process.whereis(event_store) do
      MatterEx.IM.EventStore.emit(
        event_store,
        Keyword.get(opts, :endpoint, 0),
        0x0028,
        0x00,
        2,
        %{0 => {:uint, sw_version}}
      )
    end

    {:ok, state}
  end
end
