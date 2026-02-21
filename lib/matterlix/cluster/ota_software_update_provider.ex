defmodule Matterlix.Cluster.OTASoftwareUpdateProvider do
  @moduledoc """
  Matter OTA Software Update Provider cluster (0x0029).

  Serves firmware images to OTA requestors. Handles QueryImage requests
  and provides download URLs or BDX transfer initiation.

  Endpoint 0 on OTA provider devices.
  """

  use Matterlix.Cluster, id: 0x0029, name: :ota_software_update_provider

  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  # QueryImage: requestor asks if an update is available
  command 0x00, :query_image, [
    vendor_id: :uint16,
    product_id: :uint16,
    software_version: :uint32,
    protocol_supported: :list,
    hardware_version: :uint16
  ], response_id: 0x01

  # ApplyUpdateRequest: requestor ready to apply
  command 0x02, :apply_update_request, [
    update_token: :bytes,
    new_version: :uint32
  ], response_id: 0x03

  # NotifyUpdateApplied: requestor confirms update complete
  command 0x04, :notify_update_applied, [
    update_token: :bytes,
    software_version: :uint32
  ]

  @impl Matterlix.Cluster
  def handle_command(:query_image, _params, state) do
    # QueryImageResponse: Status=NotAvailable(2)
    {:ok, %{0 => {:uint, 2}}, state}
  end

  def handle_command(:apply_update_request, _params, state) do
    # ApplyUpdateResponse: Action=Proceed(0), DelayedActionTime=0
    {:ok, %{0 => {:uint, 0}, 1 => {:uint, 0}}, state}
  end

  def handle_command(:notify_update_applied, _params, state) do
    {:ok, nil, state}
  end
end
