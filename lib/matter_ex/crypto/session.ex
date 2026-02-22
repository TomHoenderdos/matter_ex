defmodule MatterEx.Crypto.Session do
  @moduledoc """
  AES-128-CCM authenticated encryption for Matter session security.

  Matter uses AES-128-CCM with:
  - 16-byte key
  - 13-byte nonce
  - 16-byte tag (128-bit MIC)
  """

  @tag_length 16

  @doc """
  Encrypt plaintext with AES-128-CCM.

  Returns `{ciphertext, tag}` where tag is #{@tag_length} bytes.
  """
  @spec encrypt(binary(), <<_::128>>, <<_::104>>, binary()) :: {binary(), binary()}
  def encrypt(plaintext, key, nonce, aad \\ <<>>)
      when byte_size(key) == 16 and byte_size(nonce) == 13 do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_ccm, key, nonce, plaintext, aad, @tag_length, true)

    {ciphertext, tag}
  end

  @doc """
  Decrypt ciphertext with AES-128-CCM.

  Returns `{:ok, plaintext}` on success, `:error` if authentication fails.
  """
  @spec decrypt(binary(), binary(), <<_::128>>, <<_::104>>, binary()) ::
          {:ok, binary()} | :error
  def decrypt(ciphertext, tag, key, nonce, aad \\ <<>>)
      when byte_size(key) == 16 and byte_size(nonce) == 13 and byte_size(tag) == @tag_length do
    case :crypto.crypto_one_time_aead(:aes_128_ccm, key, nonce, ciphertext, aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end
end
