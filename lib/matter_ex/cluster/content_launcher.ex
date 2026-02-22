defmodule MatterEx.Cluster.ContentLauncher do
  @moduledoc """
  Matter Content Launcher cluster (0x050A).

  Launches content by URL or search. Reports accepted types
  (MIME/codec support) and supported streaming protocols.

  Device type 0x0023 (Video Player).
  """

  use MatterEx.Cluster, id: 0x050A, name: :content_launcher

  # AcceptHeader: list of MIME type strings
  attribute 0x0000, :accept_header, :list, default: ["video/mp4", "audio/aac"]
  # SupportedStreamingProtocols: bitmask (0=DASH, 1=HLS, etc.)
  attribute 0x0001, :supported_streaming_protocols, :bitmap32, default: 0x03
  attribute 0xFFFC, :feature_map, :uint32, default: 0x03
  attribute 0xFFFD, :cluster_revision, :uint16, default: 2

  command 0x00, :launch_content, [search: :struct, auto_play: :boolean, data: :string]
  command 0x01, :launch_url, [content_url: :string, display_string: :string]

  @impl MatterEx.Cluster
  def handle_command(:launch_content, _params, state) do
    # LauncherResponse: Status=Success(0)
    {:ok, %{0 => {:uint, 0}, 1 => {:string, ""}}, state}
  end

  def handle_command(:launch_url, _params, state) do
    {:ok, %{0 => {:uint, 0}, 1 => {:string, ""}}, state}
  end
end
