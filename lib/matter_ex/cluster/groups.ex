defmodule MatterEx.Cluster.Groups do
  @moduledoc """
  Matter Groups cluster (0x0004).

  Manages group membership for an endpoint. Each group is identified by
  a group ID and optional name. Group membership determines which group
  messages the endpoint processes.

  Endpoint 1+ (application endpoints).
  """

  use MatterEx.Cluster, id: 0x0004, name: :groups

  attribute 0x0000, :name_support, :uint8, default: 0x80
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 4

  command 0x00, :add_group, [group_id: :uint16, group_name: :string], response_id: 0x00
  command 0x01, :view_group, [group_id: :uint16], response_id: 0x01
  command 0x02, :get_group_membership, [group_list: :list], response_id: 0x02
  command 0x03, :remove_group, [group_id: :uint16], response_id: 0x03
  command 0x04, :remove_all_groups, []

  @impl true
  def init(opts) do
    {:ok, state} = super(opts)
    # Internal: %{group_id => group_name}
    {:ok, Map.put(state, :_groups, %{})}
  end

  @impl MatterEx.Cluster
  def handle_command(:add_group, params, state) do
    group_id = params[:group_id] || 0
    group_name = params[:group_name] || ""

    groups = Map.put(state._groups, group_id, group_name)
    state = %{state | _groups: groups}

    {:ok, %{0 => {:uint, 0}, 1 => {:uint, group_id}}, state}
  end

  def handle_command(:view_group, params, state) do
    group_id = params[:group_id] || 0

    case Map.get(state._groups, group_id) do
      nil ->
        {:ok, %{0 => {:uint, 0x8B}, 1 => {:uint, group_id}, 2 => {:string, ""}}, state}

      name ->
        {:ok, %{0 => {:uint, 0}, 1 => {:uint, group_id}, 2 => {:string, name}}, state}
    end
  end

  def handle_command(:get_group_membership, params, state) do
    requested = params[:group_list] || []

    matching =
      if requested == [] do
        Map.keys(state._groups) |> Enum.map(&{:uint, &1})
      else
        requested
        |> Enum.filter(&Map.has_key?(state._groups, &1))
        |> Enum.map(&{:uint, &1})
      end

    {:ok, %{0 => {:uint, 254 - map_size(state._groups)}, 1 => {:list, matching}}, state}
  end

  def handle_command(:remove_group, params, state) do
    group_id = params[:group_id] || 0

    {removed, groups} = Map.pop(state._groups, group_id)
    status = if removed != nil, do: 0, else: 0x8B
    state = %{state | _groups: groups}

    {:ok, %{0 => {:uint, status}, 1 => {:uint, group_id}}, state}
  end

  def handle_command(:remove_all_groups, _params, state) do
    {:ok, nil, %{state | _groups: %{}}}
  end
end
