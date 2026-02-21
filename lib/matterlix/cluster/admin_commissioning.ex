defmodule Matterlix.Cluster.AdminCommissioning do
  @moduledoc """
  Matter Administrator Commissioning cluster (0x003C).

  Controls the commissioning window for additional fabrics.
  WindowStatus: 0=WindowNotOpen, 1=EnhancedWindowOpen, 2=BasicWindowOpen.

  Required on endpoint 0.
  """

  use Matterlix.Cluster, id: 0x003C, name: :admin_commissioning

  # WindowStatus: 0=NotOpen, 1=EnhancedWindowOpen, 2=BasicWindowOpen
  attribute 0x0000, :window_status, :enum8, default: 0
  # AdminFabricIndex: fabric that opened the window (null if closed)
  attribute 0x0001, :admin_fabric_index, :uint8, default: 0
  # AdminVendorId: vendor that opened the window (null if closed)
  attribute 0x0002, :admin_vendor_id, :uint16, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :open_commissioning_window, [
    commissioning_timeout: :uint16,
    pake_passcode_verifier: :bytes,
    discriminator: :uint16,
    iterations: :uint32,
    salt: :bytes
  ]
  command 0x01, :open_basic_commissioning_window, [commissioning_timeout: :uint16]
  command 0x02, :revoke_commissioning, []

  @impl Matterlix.Cluster
  def handle_command(:open_commissioning_window, params, state) do
    timeout = params[:commissioning_timeout] || 180
    _discriminator = params[:discriminator]
    _iterations = params[:iterations]
    _salt = params[:salt]

    state = state
      |> set_attribute(:window_status, 1)
      |> Map.put(:_window_timeout, timeout)

    {:ok, nil, state}
  end

  def handle_command(:open_basic_commissioning_window, params, state) do
    timeout = params[:commissioning_timeout] || 180

    state = state
      |> set_attribute(:window_status, 2)
      |> Map.put(:_window_timeout, timeout)

    {:ok, nil, state}
  end

  def handle_command(:revoke_commissioning, _params, state) do
    state = state
      |> set_attribute(:window_status, 0)
      |> set_attribute(:admin_fabric_index, 0)
      |> set_attribute(:admin_vendor_id, 0)

    {:ok, nil, state}
  end
end
