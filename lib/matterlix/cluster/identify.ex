defmodule Matterlix.Cluster.Identify do
  @moduledoc """
  Matter Identify cluster (0x0003).

  Allows a controller to trigger a visual/audible identification action on the
  device (e.g., blink an LED) and query the remaining identify time.

  Endpoint 1+ (application endpoints).
  """

  use Matterlix.Cluster, id: 0x0003, name: :identify

  attribute 0x0000, :identify_time, :uint16, default: 0, writable: true
  attribute 0x0001, :identify_type, :enum8, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 4

  command 0x00, :identify, [identify_time: :uint16]
  command 0x40, :trigger_effect, [effect_identifier: :enum8, effect_variant: :enum8]

  @impl Matterlix.Cluster
  def handle_command(:identify, params, state) do
    time = params[:identify_time] || 0
    {:ok, nil, set_attribute(state, :identify_time, time)}
  end

  def handle_command(:trigger_effect, _params, state) do
    # TriggerEffect is a best-effort hint to the device — acknowledge and continue
    {:ok, nil, state}
  end
end
