defmodule MatterEx.Cluster.OnOff do
  @moduledoc """
  Matter OnOff cluster (0x0006).
  """

  use MatterEx.Cluster, :on_off

  attribute(:on_off, :boolean, default: false, writable: true)
  revision(4)

  command(:off)
  command(:on)
  command(:toggle)

  @impl MatterEx.Cluster
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
