defmodule MatterEx.Crypto.GroupKey do
  @moduledoc """
  Matter group key derivation.

  Derives operational group keys, per-group encryption keys, and group session IDs
  from epoch keys per Matter Core Specification section 4.15.3.
  """

  alias MatterEx.Crypto.KDF

  @doc """
  Derive the operational group key from an epoch key.

  OperationalGroupKey = HKDF(salt="", ikm=EpochKey, info="GroupKey v1.0", length=16)
  """
  @spec operational_key(binary()) :: binary()
  def operational_key(epoch_key) when byte_size(epoch_key) == 16 do
    KDF.hkdf(<<>>, epoch_key, "GroupKey v1.0", 16)
  end

  @doc """
  Derive the encryption key for a specific group.

  GroupEncryptKey = HKDF(salt="", ikm=OperationalGroupKey, info="GroupMessaging" || GroupId_LE16, length=16)
  """
  @spec encryption_key(binary(), non_neg_integer()) :: binary()
  def encryption_key(operational_key, group_id) when byte_size(operational_key) == 16 do
    info = <<"GroupMessaging", group_id::little-16>>
    KDF.hkdf(<<>>, operational_key, info, 16)
  end

  @doc """
  Derive the privacy key from an operational group key.

  GroupPrivacyKey = HKDF(salt="", ikm=OperationalGroupKey, info="GroupPrivacy", length=16)
  """
  @spec privacy_key(binary()) :: binary()
  def privacy_key(operational_key) when byte_size(operational_key) == 16 do
    KDF.hkdf(<<>>, operational_key, "GroupPrivacy", 16)
  end

  @doc """
  Derive the group session ID from an operational group key.

  Lower 16 bits of HMAC-SHA256(OperationalGroupKey, "GroupSession").
  """
  @spec session_id(binary()) :: non_neg_integer()
  def session_id(operational_key) when byte_size(operational_key) == 16 do
    <<sid::little-16, _::binary>> = :crypto.mac(:hmac, :sha256, operational_key, "GroupSession")
    sid
  end
end
