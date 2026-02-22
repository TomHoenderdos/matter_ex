defmodule MatterEx.Session do
  @moduledoc """
  Represents an established secure session after PASE or CASE completes.

  Derives directional encryption keys from the raw session key (Ke) using
  HKDF-SHA256 per Matter spec section 4.13.2.6.1:

      keys = HKDF(salt="", ikm=Ke, info="SessionKeys", length=48)
      I2R_Key = keys[0:16]              # Initiator → Responder
      R2I_Key = keys[16:32]             # Responder → Initiator
      AttestationChallenge = keys[32:48] # Used in CASE
  """

  alias MatterEx.Crypto.KDF
  alias MatterEx.Protocol.Counter

  defstruct [
    :local_session_id,
    :peer_session_id,
    :encrypt_key,
    :decrypt_key,
    :attestation_challenge,
    :local_node_id,
    :peer_node_id,
    :counter,
    :auth_mode,
    :fabric_index
  ]

  @type t :: %__MODULE__{
    local_session_id: non_neg_integer(),
    peer_session_id: non_neg_integer(),
    encrypt_key: binary(),
    decrypt_key: binary(),
    attestation_challenge: binary(),
    local_node_id: non_neg_integer(),
    peer_node_id: non_neg_integer(),
    counter: Counter.t(),
    auth_mode: :pase | :case,
    fabric_index: non_neg_integer() | nil
  }

  @doc """
  Create a new session with derived directional keys and a fresh message counter.

  Required opts: `:local_session_id`, `:peer_session_id`, `:encryption_key`

  Optional opts:
  - `:role` — `:initiator` or `:responder` (default `:responder`).
    Determines which derived key is used for encrypt vs decrypt.
  - `:local_node_id` — source node ID for nonce construction (default 0)
  - `:peer_node_id` — peer node ID for nonce construction (default 0)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    ke = Keyword.fetch!(opts, :encryption_key)
    role = Keyword.get(opts, :role, :responder)
    salt = Keyword.get(opts, :salt, <<>>)

    {i2r, r2i, challenge} = derive_session_keys(ke, salt)

    {encrypt_key, decrypt_key} =
      case role do
        :initiator -> {i2r, r2i}
        :responder -> {r2i, i2r}
      end

    %__MODULE__{
      local_session_id: Keyword.fetch!(opts, :local_session_id),
      peer_session_id: Keyword.fetch!(opts, :peer_session_id),
      encrypt_key: encrypt_key,
      decrypt_key: decrypt_key,
      attestation_challenge: challenge,
      local_node_id: Keyword.get(opts, :local_node_id, 0),
      peer_node_id: Keyword.get(opts, :peer_node_id, 0),
      counter: Counter.new(),
      auth_mode: Keyword.get(opts, :auth_mode, :pase),
      fabric_index: Keyword.get(opts, :fabric_index)
    }
  end

  @doc """
  Derive I2R_Key, R2I_Key, and AttestationChallenge from session Ke.

  For PASE sessions, salt is empty. For CASE sessions, salt is
  `IPK(16) || SHA256(sigma1 || sigma2 || sigma3)(32)` = 48 bytes.
  """
  @spec derive_session_keys(binary(), binary()) :: {binary(), binary(), binary()}
  def derive_session_keys(ke, salt \\ <<>>) when is_binary(ke) and byte_size(ke) >= 16 do
    keys = KDF.hkdf(salt, ke, "SessionKeys", 48)
    i2r = binary_part(keys, 0, 16)
    r2i = binary_part(keys, 16, 16)
    challenge = binary_part(keys, 32, 16)
    {i2r, r2i, challenge}
  end
end
