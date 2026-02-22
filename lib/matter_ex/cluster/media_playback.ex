defmodule MatterEx.Cluster.MediaPlayback do
  @moduledoc """
  Matter Media Playback cluster (0x0506).

  Controls media playback: play, pause, stop, skip, seek.
  CurrentState tracks the playback state.

  Device type 0x0023 (Video Player), 0x0024 (Basic Video Player).
  """

  use MatterEx.Cluster, id: 0x0506, name: :media_playback

  # CurrentState: 0=Playing, 1=Paused, 2=NotPlaying, 3=Buffering
  attribute 0x0000, :current_state, :enum8, default: 2
  # StartTime: epoch-us of media start (null if unknown)
  attribute 0x0001, :start_time, :uint64, default: 0
  # Duration: media duration in ms (null if live/unknown)
  attribute 0x0002, :duration, :uint64, default: 0
  # SampledPosition: playback position struct
  attribute 0x0003, :sampled_position, :struct, default: %{updated_at: 0, position: 0}
  # PlaybackSpeed: float, 1.0 = normal
  attribute 0x0004, :playback_speed, :float, default: 1.0
  # SeekRangeEnd: ms
  attribute 0x0005, :seek_range_end, :uint64, default: 0
  # SeekRangeStart: ms
  attribute 0x0006, :seek_range_start, :uint64, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0x01
  attribute 0xFFFD, :cluster_revision, :uint16, default: 2

  command 0x00, :play, []
  command 0x01, :pause, []
  command 0x02, :stop, []
  command 0x04, :skip_forward, [delta_position_milliseconds: :uint64]
  command 0x05, :skip_backward, [delta_position_milliseconds: :uint64]
  command 0x0B, :seek, [position: :uint64]

  @impl MatterEx.Cluster
  def handle_command(:play, _params, state) do
    state = set_attribute(state, :current_state, 0)
    {:ok, %{0 => {:uint, 0}}, state}
  end

  def handle_command(:pause, _params, state) do
    state = set_attribute(state, :current_state, 1)
    {:ok, %{0 => {:uint, 0}}, state}
  end

  def handle_command(:stop, _params, state) do
    state = set_attribute(state, :current_state, 2)
    {:ok, %{0 => {:uint, 0}}, state}
  end

  def handle_command(:skip_forward, _params, state) do
    {:ok, %{0 => {:uint, 0}}, state}
  end

  def handle_command(:skip_backward, _params, state) do
    {:ok, %{0 => {:uint, 0}}, state}
  end

  def handle_command(:seek, params, state) do
    position = params[:position] || 0
    state = set_attribute(state, :sampled_position, %{updated_at: 0, position: position})
    {:ok, %{0 => {:uint, 0}}, state}
  end
end
