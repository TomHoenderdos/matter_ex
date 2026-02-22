defmodule MatterEx.Cluster.AudioOutput do
  @moduledoc """
  Matter Audio Output cluster (0x050B).

  Lists available audio outputs and manages the active output selection.
  OutputType: 0=HDMI, 1=BT, 2=Optical, 3=Headphone, 4=Internal, 5=Other.

  Device type 0x0023 (Video Player).
  """

  use MatterEx.Cluster, id: 0x050B, name: :audio_output

  # OutputList: list of output structs
  attribute 0x0000, :output_list, :list, default: [
    %{index: 0, output_type: 0, name: "HDMI 1"},
    %{index: 1, output_type: 0, name: "HDMI 2"},
    %{index: 2, output_type: 4, name: "Built-in Speaker"}
  ]
  # CurrentOutput: index of active output
  attribute 0x0001, :current_output, :uint8, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0x01
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :select_output, [index: :uint8]
  command 0x01, :rename_output, [index: :uint8, name: :string]

  @impl MatterEx.Cluster
  def handle_command(:select_output, params, state) do
    index = params[:index] || 0
    outputs = get_attribute(state, :output_list) || []
    valid_indices = Enum.map(outputs, & &1.index)

    if index in valid_indices do
      state = set_attribute(state, :current_output, index)
      {:ok, nil, state}
    else
      {:error, :constraint_error}
    end
  end

  def handle_command(:rename_output, params, state) do
    index = params[:index] || 0
    new_name = params[:name] || ""
    outputs = get_attribute(state, :output_list) || []

    updated = Enum.map(outputs, fn out ->
      if out.index == index, do: %{out | name: new_name}, else: out
    end)

    state = set_attribute(state, :output_list, updated)
    {:ok, nil, state}
  end
end
