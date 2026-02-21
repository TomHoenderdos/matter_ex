defmodule Matterlix.Cluster.ModeSelect do
  @moduledoc """
  Matter Mode Select cluster (0x0050).

  Allows selection from a list of operating modes. Each mode has a
  label and value. Used for appliance modes (e.g., washing machine cycles).

  Device type 0x0027 (Mode Select).
  """

  use Matterlix.Cluster, id: 0x0050, name: :mode_select

  # Description: human-readable cluster description
  attribute 0x0000, :description, :string, default: "Mode"
  # StandardNamespace: null or enum namespace
  attribute 0x0001, :standard_namespace, :uint16, default: 0
  # SupportedModes: list of mode option structs
  attribute 0x0002, :supported_modes, :list, default: [
    %{label: "Normal", mode: 0, semantic_tags: []},
    %{label: "Eco", mode: 1, semantic_tags: []},
    %{label: "Quick", mode: 2, semantic_tags: []}
  ]
  # CurrentMode
  attribute 0x0003, :current_mode, :uint8, default: 0
  # StartUpMode (null = no change on startup)
  attribute 0x0004, :start_up_mode, :uint8, default: 0, writable: true
  # OnMode (null = no override)
  attribute 0x0005, :on_mode, :uint8, default: 0, writable: true
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 2

  command 0x00, :change_to_mode, [new_mode: :uint8]

  @impl Matterlix.Cluster
  def handle_command(:change_to_mode, params, state) do
    new_mode = params[:new_mode] || 0
    supported = get_attribute(state, :supported_modes) || []
    valid_modes = Enum.map(supported, & &1.mode)

    if new_mode in valid_modes do
      state = set_attribute(state, :current_mode, new_mode)
      {:ok, nil, state}
    else
      {:error, :constraint_error}
    end
  end
end
