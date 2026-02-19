defmodule Matterlix.Cluster.GeneralCommissioning do
  @moduledoc """
  Matter General Commissioning cluster (0x0030).

  Controls the commissioning state machine. Endpoint 0 only.
  """

  use Matterlix.Cluster, id: 0x0030, name: :general_commissioning

  alias Matterlix.Commissioning

  attribute 0x0000, :breadcrumb, :uint64, default: 0, writable: true
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :arm_fail_safe, [expiry_length: :uint16, breadcrumb: :uint64]
  command 0x04, :commissioning_complete, []

  @impl Matterlix.Cluster
  def handle_command(:arm_fail_safe, params, state) do
    if Process.whereis(Commissioning) do
      Commissioning.arm()
    end

    state = set_attribute(state, :breadcrumb, params[:breadcrumb] || 0)
    # ArmFailSafeResponse: ErrorCode=OK(0), DebugText=""
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
