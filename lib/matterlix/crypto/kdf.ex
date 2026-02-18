defmodule Matterlix.Crypto.KDF do
  @moduledoc """
  Key derivation functions for Matter cryptography.

  - HKDF-SHA256 (RFC 5869) — used for session key derivation
  - PBKDF2-HMAC-SHA256 (RFC 2898) — used for SPAKE2+ verifier computation
  """

  @hash_len 32

  @doc """
  HKDF extract + expand in one call.

  Derives `length` bytes of key material from input keying material.
  """
  @spec hkdf(binary(), binary(), binary(), pos_integer()) :: binary()
  def hkdf(salt, ikm, info, length) do
    ikm
    |> hkdf_extract(salt)
    |> hkdf_expand(info, length)
  end

  @doc """
  HKDF-Extract: PRK = HMAC-SHA256(salt, IKM)

  If salt is empty, uses a zero-filled string of hash length.
  """
  @spec hkdf_extract(binary(), binary()) :: binary()
  def hkdf_extract(ikm, salt \\ <<>>) do
    salt = if salt == <<>>, do: :binary.copy(<<0>>, @hash_len), else: salt
    hmac(salt, ikm)
  end

  @doc """
  HKDF-Expand: derive `length` bytes from PRK and info.

  OKM = T(1) || T(2) || ... where T(i) = HMAC(PRK, T(i-1) || info || i)
  """
  @spec hkdf_expand(binary(), binary(), pos_integer()) :: binary()
  def hkdf_expand(prk, info, length) when length > 0 and length <= 255 * @hash_len do
    n = ceil(length / @hash_len)

    {okm, _} =
      Enum.reduce(1..n, {<<>>, <<>>}, fn i, {acc, prev} ->
        t = hmac(prk, <<prev::binary, info::binary, i::8>>)
        {<<acc::binary, t::binary>>, t}
      end)

    binary_part(okm, 0, length)
  end

  @doc """
  PBKDF2-HMAC-SHA256.

  Derives `dk_length` bytes from password, salt, and iteration count.
  """
  @spec pbkdf2_sha256(binary(), binary(), pos_integer(), pos_integer()) :: binary()
  def pbkdf2_sha256(password, salt, iterations, dk_length)
      when iterations > 0 and dk_length > 0 do
    block_count = ceil(dk_length / @hash_len)

    dk =
      for block <- 1..block_count, into: <<>> do
        pbkdf2_block(password, salt, iterations, block)
      end

    binary_part(dk, 0, dk_length)
  end

  # Compute one PBKDF2 block: U1 xor U2 xor ... xor Uc
  # U1 = HMAC(password, salt || block_index_big_endian_32)
  # Ui = HMAC(password, U_{i-1})
  defp pbkdf2_block(password, salt, iterations, block_index) do
    u1 = hmac(password, <<salt::binary, block_index::unsigned-big-32>>)

    {result, _} =
      Enum.reduce(2..iterations//1, {u1, u1}, fn _i, {acc, prev} ->
        u = hmac(password, prev)
        {:crypto.exor(acc, u), u}
      end)

    result
  end

  defp hmac(key, data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end
end
