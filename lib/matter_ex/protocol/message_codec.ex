defmodule MatterEx.Protocol.MessageCodec do
  @moduledoc """
  Matter message frame encode/decode.

  Handles the full message wire format: plaintext message header (AAD)
  followed by protocol header + payload (encrypted for active sessions)
  and a 16-byte MIC tag.
  """

  alias MatterEx.Protocol.MessageCodec.{Header, ProtoHeader}
  alias MatterEx.Crypto.Session

  @mic_size 16

  @type message :: %{header: Header.t(), proto: ProtoHeader.t()}

  @doc """
  Encode a plaintext message (used during PASE setup, session_id = 0).
  """
  @spec encode(Header.t(), ProtoHeader.t()) :: iodata()
  def encode(%Header{} = header, %ProtoHeader{} = proto) do
    [Header.encode(header), ProtoHeader.encode(proto)]
  end

  @doc """
  Encode an encrypted message. The message header becomes AAD,
  the protocol header + payload are encrypted, and the 16-byte MIC is appended.
  """
  @spec encode_encrypted(Header.t(), ProtoHeader.t(), binary(), binary()) :: iodata()
  def encode_encrypted(%Header{} = header, %ProtoHeader{} = proto, key, nonce) do
    aad = IO.iodata_to_binary(Header.encode(header))
    plaintext = IO.iodata_to_binary(ProtoHeader.encode(proto))
    {ciphertext, tag} = Session.encrypt(plaintext, key, nonce, aad)
    [aad, ciphertext, tag]
  end

  @doc """
  Decode a plaintext message frame.
  """
  @spec decode(binary()) :: {:ok, message()} | {:error, atom()}
  def decode(binary) when is_binary(binary) do
    with {:ok, header, rest} <- Header.decode(binary),
         {:ok, proto} <- ProtoHeader.decode(rest) do
      {:ok, %{header: header, proto: proto}}
    end
  end

  @doc """
  Decode an encrypted message frame. The plaintext header is decoded first,
  then the remaining ciphertext (minus the 16-byte MIC) is decrypted.
  """
  @spec decode_encrypted(binary(), binary(), binary()) :: {:ok, message()} | {:error, atom()}
  def decode_encrypted(binary, key, nonce) when is_binary(binary) do
    with {:ok, header, rest} <- Header.decode(binary) do
      payload_size = byte_size(rest) - @mic_size

      if payload_size < 0 do
        {:error, :truncated_mic}
      else
        <<ciphertext::binary-size(payload_size), tag::binary-size(@mic_size)>> = rest
        aad = IO.iodata_to_binary(Header.encode(header))

        case Session.decrypt(ciphertext, tag, key, nonce, aad) do
          {:ok, plaintext} ->
            with {:ok, proto} <- ProtoHeader.decode(plaintext) do
              {:ok, %{header: header, proto: proto}}
            end

          :error ->
            {:error, :authentication_failed}
        end
      end
    end
  end

  @doc """
  Build a 13-byte AES-CCM nonce per Matter spec.

      <<security_flags::8, message_counter::little-32, source_node_id::little-64>>
  """
  @spec build_nonce(byte(), non_neg_integer(), non_neg_integer()) :: binary()
  def build_nonce(security_flags, message_counter, source_node_id \\ 0) do
    <<security_flags::8, message_counter::little-32, source_node_id::little-64>>
  end
end
