defmodule Matterlix.Session do
  @moduledoc """
  Represents an established secure session after PASE or CASE completes.

  Holds session IDs, the encryption key (Ke), and an outgoing message counter.
  """

  alias Matterlix.Protocol.Counter

  defstruct [
    :local_session_id,
    :peer_session_id,
    :encryption_key,
    :counter
  ]

  @type t :: %__MODULE__{
    local_session_id: non_neg_integer(),
    peer_session_id: non_neg_integer(),
    encryption_key: binary(),
    counter: Counter.t()
  }

  @doc """
  Create a new session with a fresh message counter.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      local_session_id: Keyword.fetch!(opts, :local_session_id),
      peer_session_id: Keyword.fetch!(opts, :peer_session_id),
      encryption_key: Keyword.fetch!(opts, :encryption_key),
      counter: Counter.new()
    }
  end
end
