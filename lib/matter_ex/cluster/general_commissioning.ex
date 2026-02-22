defmodule MatterEx.Cluster.GeneralCommissioning do
  @moduledoc """
  Matter General Commissioning cluster (0x0030).

  Controls the commissioning state machine. Endpoint 0 only.
  """

  use MatterEx.Cluster, id: 0x0030, name: :general_commissioning

  alias MatterEx.Commissioning

  attribute 0x0000, :breadcrumb, :uint64, default: 0, writable: true
  attribute 0x0001, :basic_commissioning_info, :struct, default: %{0 => {:uint, 60}, 1 => {:uint, 900}}
  attribute 0x0002, :regulatory_config, :enum8, default: 0
  attribute 0x0003, :location_capability, :enum8, default: 2
  attribute 0x0004, :supports_concurrent_connection, :boolean, default: true
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :arm_fail_safe, [expiry_length: :uint16, breadcrumb: :uint64], response_id: 0x01
  command 0x02, :set_regulatory_config, [new_regulatory_config: :uint8, country_code: :string, breadcrumb: :uint64], response_id: 0x03
  command 0x04, :commissioning_complete, [], response_id: 0x05

  @impl MatterEx.Cluster
  def handle_command(:arm_fail_safe, params, state) do
    if Process.whereis(Commissioning) do
      Commissioning.arm()
    end

    state = set_attribute(state, :breadcrumb, params[:breadcrumb] || 0)
    # ArmFailSafeResponse: ErrorCode=OK(0), DebugText=""
    {:ok, %{0 => {:uint, 0}, 1 => {:string, ""}}, state}
  end

  def handle_command(:set_regulatory_config, params, state) do
    state = set_attribute(state, :breadcrumb, params[:breadcrumb] || 0)
    # SetRegulatoryConfigResponse: ErrorCode=OK(0), DebugText=""
    {:ok, %{0 => {:uint, 0}, 1 => {:string, ""}}, state}
  end

  def handle_command(:commissioning_complete, _params, state) do
    if Process.whereis(Commissioning) do
      Commissioning.complete()
    end

    # CommissioningCompleteResponse: ErrorCode=OK(0), DebugText=""
    {:ok, %{0 => {:uint, 0}, 1 => {:string, ""}}, state}
  end
end
