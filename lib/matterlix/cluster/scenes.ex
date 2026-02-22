defmodule Matterlix.Cluster.Scenes do
  @moduledoc """
  Matter Scenes cluster (0x0005).

  Stores and recalls named scenes — snapshots of cluster attribute values
  that can be applied atomically. Each scene belongs to a group and has
  a scene ID, name, and transition time.

  Endpoint 1+ (application endpoints).
  """

  use Matterlix.Cluster, id: 0x0005, name: :scenes

  attribute 0x0000, :scene_count, :uint8, default: 0
  attribute 0x0001, :current_scene, :uint8, default: 0
  attribute 0x0002, :current_group, :uint16, default: 0
  attribute 0x0003, :scene_valid, :boolean, default: false
  attribute 0x0004, :name_support, :uint8, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 5

  command 0x00, :add_scene, [group_id: :uint16, scene_id: :uint8, transition_time: :uint16, scene_name: :string], response_id: 0x00
  command 0x01, :view_scene, [group_id: :uint16, scene_id: :uint8], response_id: 0x01
  command 0x02, :remove_scene, [group_id: :uint16, scene_id: :uint8], response_id: 0x02
  command 0x03, :remove_all_scenes, [group_id: :uint16], response_id: 0x03
  command 0x04, :store_scene, [group_id: :uint16, scene_id: :uint8], response_id: 0x04
  command 0x05, :recall_scene, [group_id: :uint16, scene_id: :uint8]
  command 0x06, :get_scene_membership, [group_id: :uint16], response_id: 0x06

  @impl true
  def init(opts) do
    {:ok, state} = super(opts)
    # Internal: %{{group_id, scene_id} => scene_data}
    {:ok, Map.put(state, :_scenes, %{})}
  end

  @impl Matterlix.Cluster
  def handle_command(:add_scene, params, state) do
    group_id = params[:group_id] || 0
    scene_id = params[:scene_id] || 0

    scene = %{
      group_id: group_id,
      scene_id: scene_id,
      transition_time: params[:transition_time] || 0,
      scene_name: params[:scene_name] || ""
    }

    scenes = Map.put(state._scenes, {group_id, scene_id}, scene)
    state = %{state | _scenes: scenes}
    state = set_attribute(state, :scene_count, map_size(scenes))

    {:ok, %{0 => {:uint, 0}, 1 => {:uint, group_id}, 2 => {:uint, scene_id}}, state}
  end

  def handle_command(:view_scene, params, state) do
    group_id = params[:group_id] || 0
    scene_id = params[:scene_id] || 0

    case Map.get(state._scenes, {group_id, scene_id}) do
      nil ->
        {:ok, %{0 => {:uint, 0x8B}, 1 => {:uint, group_id}, 2 => {:uint, scene_id}}, state}

      scene ->
        {:ok, %{
          0 => {:uint, 0},
          1 => {:uint, group_id},
          2 => {:uint, scene_id},
          3 => {:uint, scene.transition_time},
          4 => {:string, scene.scene_name}
        }, state}
    end
  end

  def handle_command(:remove_scene, params, state) do
    group_id = params[:group_id] || 0
    scene_id = params[:scene_id] || 0

    {removed, scenes} = Map.pop(state._scenes, {group_id, scene_id})
    status = if removed, do: 0, else: 0x8B
    state = %{state | _scenes: scenes}
    state = set_attribute(state, :scene_count, map_size(scenes))

    {:ok, %{0 => {:uint, status}, 1 => {:uint, group_id}, 2 => {:uint, scene_id}}, state}
  end

  def handle_command(:remove_all_scenes, params, state) do
    group_id = params[:group_id] || 0
    scenes = Map.reject(state._scenes, fn {{gid, _sid}, _} -> gid == group_id end)
    state = %{state | _scenes: scenes}
    state = set_attribute(state, :scene_count, map_size(scenes))

    {:ok, %{0 => {:uint, 0}, 1 => {:uint, group_id}}, state}
  end

  def handle_command(:store_scene, params, state) do
    group_id = params[:group_id] || 0
    scene_id = params[:scene_id] || 0

    scene = %{
      group_id: group_id,
      scene_id: scene_id,
      transition_time: 0,
      scene_name: ""
    }

    scenes = Map.put(state._scenes, {group_id, scene_id}, scene)
    state = %{state | _scenes: scenes}
    state = set_attribute(state, :scene_count, map_size(scenes))
    state = state |> set_attribute(:current_scene, scene_id) |> set_attribute(:current_group, group_id) |> set_attribute(:scene_valid, true)

    {:ok, %{0 => {:uint, 0}, 1 => {:uint, group_id}, 2 => {:uint, scene_id}}, state}
  end

  def handle_command(:recall_scene, params, state) do
    group_id = params[:group_id] || 0
    scene_id = params[:scene_id] || 0

    case Map.get(state._scenes, {group_id, scene_id}) do
      nil ->
        {:error, :not_found}

      _scene ->
        state = state |> set_attribute(:current_scene, scene_id) |> set_attribute(:current_group, group_id) |> set_attribute(:scene_valid, true)
        {:ok, nil, state}
    end
  end

  def handle_command(:get_scene_membership, params, state) do
    group_id = params[:group_id] || 0

    scene_ids =
      state._scenes
      |> Map.keys()
      |> Enum.filter(fn {gid, _sid} -> gid == group_id end)
      |> Enum.map(fn {_gid, sid} -> {:uint, sid} end)

    {:ok, %{
      0 => {:uint, 0},
      1 => {:uint, 254 - map_size(state._scenes)},
      2 => {:uint, group_id},
      3 => {:list, scene_ids}
    }, state}
  end
end
