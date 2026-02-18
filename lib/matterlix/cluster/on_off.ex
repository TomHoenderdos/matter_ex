defmodule Matterlix.Cluster.OnOff do
  @moduledoc """
  Matter OnOff cluster (0x0006).
  """

  use Matterlix.Cluster, id: 0x0006, name: :on_off

  attribute 0x0000, :on_off, :boolean, default: false, writable: true
  attribute 0xFFFD, :cluster_revision, :uint16, default: 4

  command 0x00, :off, []
  command 0x01, :on, []
  command 0x02, :toggle, []

  @impl Matterlix.Cluster
  def handle_command(:off, _params, state) do
    {:ok, nil, set_attribute(state, :on_off, false)}
  end

  def handle_command(:on, _params, state) do
    {:ok, nil, set_attribute(state, :on_off, true)}
  end

  def handle_command(:toggle, _params, state) do
    {:ok, nil, set_attribute(state, :on_off, !get_attribute(state, :on_off))}
  end
end
