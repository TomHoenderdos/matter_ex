defmodule MatterEx.PASE.Messages do
  @moduledoc """
  TLV codec for PASE commissioning messages.

  Each message type has an encode and decode function.
  Encoding produces a TLV binary; decoding returns a plain map.
  """

  alias MatterEx.TLV

  # ── PBKDFParamRequest (opcode 0x20) ──────────────────────────────

  @doc """
  Encode a PBKDFParamRequest.

  Options:
  - `:passcode_id` — uint16, defaults to 0
  - `:has_pbkdf_params` — bool, defaults to false
  """
  @spec encode_pbkdf_param_request(binary(), non_neg_integer(), keyword()) :: binary()
  def encode_pbkdf_param_request(initiator_random, session_id, opts \\ []) do
    TLV.encode(%{
      1 => {:bytes, initiator_random},
      2 => {:uint, session_id},
      3 => {:uint, Keyword.get(opts, :passcode_id, 0)},
      4 => {:bool, Keyword.get(opts, :has_pbkdf_params, false)}
    })
  end

  @spec decode_pbkdf_param_request(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_pbkdf_param_request(data) do
    with {:ok, decoded} <- safe_decode(data),
         %{1 => random, 2 => session_id} <- decoded do
      {:ok, %{
        initiator_random: random,
        initiator_session_id: session_id,
        passcode_id: Map.get(decoded, 3, 0),
        has_pbkdf_params: Map.get(decoded, 4, false)
      }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # ── PBKDFParamResponse (opcode 0x21) ─────────────────────────────

  @spec encode_pbkdf_param_response(binary(), binary(), non_neg_integer(), pos_integer(), binary()) :: binary()
  def encode_pbkdf_param_response(initiator_random, responder_random, session_id, iterations, salt) do
    TLV.encode(%{
      1 => {:bytes, initiator_random},
      2 => {:bytes, responder_random},
      3 => {:uint, session_id},
      4 => {:struct, %{
        1 => {:uint, iterations},
        2 => {:bytes, salt}
      }}
    })
  end

  @spec decode_pbkdf_param_response(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_pbkdf_param_response(data) do
    with {:ok, decoded} <- safe_decode(data),
         %{1 => init_random, 2 => resp_random, 3 => session_id, 4 => %{1 => iterations, 2 => salt}} <- decoded do
      {:ok, %{
        initiator_random: init_random,
        responder_random: resp_random,
        responder_session_id: session_id,
        pbkdf_parameters: %{iterations: iterations, salt: salt}
      }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # ── Pake1 (opcode 0x22) ──────────────────────────────────────────

  @spec encode_pake1(binary()) :: binary()
  def encode_pake1(pa) do
    TLV.encode(%{1 => {:bytes, pa}})
  end

  @spec decode_pake1(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_pake1(data) do
    with {:ok, %{1 => pa}} when is_binary(pa) <- safe_decode(data) do
      {:ok, %{pa: pa}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # ── Pake2 (opcode 0x23) ──────────────────────────────────────────

  @spec encode_pake2(binary(), binary()) :: binary()
  def encode_pake2(pb, cb) do
    TLV.encode(%{1 => {:bytes, pb}, 2 => {:bytes, cb}})
  end

  @spec decode_pake2(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_pake2(data) do
    with {:ok, %{1 => pb, 2 => cb}} when is_binary(pb) and is_binary(cb) <- safe_decode(data) do
      {:ok, %{pb: pb, cb: cb}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # ── Pake3 (opcode 0x24) ──────────────────────────────────────────

  @spec encode_pake3(binary()) :: binary()
  def encode_pake3(ca) do
    TLV.encode(%{1 => {:bytes, ca}})
  end

  @spec decode_pake3(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_pake3(data) do
    with {:ok, %{1 => ca}} when is_binary(ca) <- safe_decode(data) do
      {:ok, %{ca: ca}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  defp safe_decode(data) do
    {:ok, TLV.decode(data)}
  rescue
    _ -> {:error, :invalid_message}
  end
end
