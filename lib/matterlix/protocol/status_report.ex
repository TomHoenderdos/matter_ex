defmodule Matterlix.Protocol.StatusReport do
  @moduledoc """
  Matter StatusReport wire format codec.

  StatusReport uses a fixed binary layout (NOT TLV):

      <<general_code::16-little, protocol_id::32-little, protocol_code::16-little>>

  Used as the final message in PASE/CASE session establishment
  and for general protocol-level status reporting.
  """

  defstruct general_code: 0, protocol_id: 0, protocol_code: 0

  @type t :: %__MODULE__{
    general_code: non_neg_integer(),
    protocol_id: non_neg_integer(),
    protocol_code: non_neg_integer()
  }

  # General status codes
  @success 0
  @failure 1

  def general_success, do: @success
  def general_failure, do: @failure

  # Secure Channel protocol codes
  @session_establishment_success 0x0000
  @no_shared_trust_roots 0x0001
  @invalid_parameter 0x0002
  @close_session 0x0003

  def session_establishment_success, do: @session_establishment_success
  def no_shared_trust_roots, do: @no_shared_trust_roots
  def invalid_parameter, do: @invalid_parameter
  def close_session, do: @close_session

  @doc """
  Encode a StatusReport to binary.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = sr) do
    <<sr.general_code::unsigned-little-16,
      sr.protocol_id::unsigned-little-32,
      sr.protocol_code::unsigned-little-16>>
  end

  @doc """
  Decode a StatusReport from binary.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_status_report}
  def decode(<<general::unsigned-little-16, protocol_id::unsigned-little-32, protocol_code::unsigned-little-16, _rest::binary>>) do
    {:ok, %__MODULE__{
      general_code: general,
      protocol_id: protocol_id,
      protocol_code: protocol_code
    }}
  end

  def decode(_), do: {:error, :invalid_status_report}
end
