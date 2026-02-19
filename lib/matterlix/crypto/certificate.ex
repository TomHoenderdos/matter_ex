defmodule Matterlix.Crypto.Certificate do
  @moduledoc """
  ECDSA P-256 signing/verification for Matter CASE authentication.

  Wraps Erlang's `:crypto` and `:public_key` modules.
  """

  @curve :secp256r1

  @doc """
  Generate a new P-256 keypair.

  Returns `{public_key, private_key}` where:
  - public_key is a 65-byte SEC1 uncompressed point (0x04 || x || y)
  - private_key is a 32-byte scalar
  """
  @spec generate_keypair() :: {binary(), binary()}
  def generate_keypair do
    {pub, priv} = :crypto.generate_key(:ecdh, @curve)
    {pub, priv}
  end

  @doc """
  Sign a message with ECDSA-SHA256 over P-256.

  Returns the DER-encoded signature.
  """
  @spec sign(binary(), binary()) :: binary()
  def sign(message, private_key) do
    :crypto.sign(:ecdsa, :sha256, message, [private_key, @curve])
  end

  @doc """
  Verify an ECDSA-SHA256 signature over P-256.
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(message, signature, public_key) do
    :crypto.verify(:ecdsa, :sha256, message, signature, [public_key, @curve])
  end

  @doc """
  Compute ECDH shared secret (P-256 x-coordinate, 32 bytes).
  """
  @spec ecdh(binary(), binary()) :: binary()
  def ecdh(peer_public_key, my_private_key) do
    :crypto.compute_key(:ecdh, peer_public_key, my_private_key, @curve)
  end
end
