defmodule Matterlix.CASE.Messages do
  @moduledoc """
  TLV codec for CASE Sigma protocol messages.

  Each message type has an encode and decode function.
  Encoding produces a TLV binary; decoding returns a plain map.
  """

  alias Matterlix.TLV
  alias Matterlix.Crypto.{KDF, Session}

  # Matter certificate DN OIDs
  @matter_node_id_oid {1, 3, 6, 1, 4, 1, 37244, 1, 1}
  @matter_fabric_id_oid {1, 3, 6, 1, 4, 1, 37244, 1, 5}

  # ── Sigma1 (opcode 0x30) ───────────────────────────────────────

  @spec encode_sigma1(binary(), non_neg_integer(), binary(), binary()) :: binary()
  def encode_sigma1(initiator_random, session_id, destination_id, eph_pub) do
    TLV.encode(%{
      1 => {:bytes, initiator_random},
      2 => {:uint, session_id},
      3 => {:bytes, destination_id},
      4 => {:bytes, eph_pub}
    })
  end

  @spec decode_sigma1(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_sigma1(data) do
    with {:ok, decoded} <- safe_decode(data),
         %{1 => random, 2 => session_id, 3 => dest_id, 4 => eph_pub} <- decoded do
      {:ok, %{
        initiator_random: random,
        initiator_session_id: session_id,
        destination_id: dest_id,
        initiator_eph_pub: eph_pub
      }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # ── Sigma2 (opcode 0x31) ───────────────────────────────────────

  @spec encode_sigma2(binary(), non_neg_integer(), binary(), binary()) :: binary()
  def encode_sigma2(responder_random, session_id, eph_pub, encrypted2) do
    TLV.encode(%{
      1 => {:bytes, responder_random},
      2 => {:uint, session_id},
      3 => {:bytes, eph_pub},
      4 => {:bytes, encrypted2}
    })
  end

  @spec decode_sigma2(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_sigma2(data) do
    with {:ok, decoded} <- safe_decode(data),
         %{1 => random, 2 => session_id, 3 => eph_pub, 4 => encrypted2} <- decoded do
      {:ok, %{
        responder_random: random,
        responder_session_id: session_id,
        responder_eph_pub: eph_pub,
        encrypted2: encrypted2
      }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # ── Sigma3 (opcode 0x32) ───────────────────────────────────────

  @spec encode_sigma3(binary()) :: binary()
  def encode_sigma3(encrypted3) do
    TLV.encode(%{1 => {:bytes, encrypted3}})
  end

  @spec decode_sigma3(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_sigma3(data) do
    with {:ok, %{1 => encrypted3}} when is_binary(encrypted3) <- safe_decode(data) do
      {:ok, %{encrypted3: encrypted3}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # ── TBEData2 (inner payload of Sigma2.encrypted2) ─────────────

  @spec encode_tbe_data2(binary(), binary() | nil, binary(), binary()) :: binary()
  def encode_tbe_data2(noc, icac, signature, resumption_id) do
    fields = %{
      1 => {:bytes, noc},
      3 => {:bytes, signature},
      4 => {:bytes, resumption_id}
    }

    fields = if icac, do: Map.put(fields, 2, {:bytes, icac}), else: fields
    TLV.encode(fields)
  end

  @spec decode_tbe_data2(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_tbe_data2(data) do
    with {:ok, decoded} <- safe_decode(data),
         %{1 => noc, 3 => signature, 4 => resumption_id} <- decoded do
      {:ok, %{
        noc: noc,
        icac: Map.get(decoded, 2),
        signature: signature,
        resumption_id: resumption_id
      }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # ── TBEData3 (inner payload of Sigma3.encrypted3) ─────────────

  @spec encode_tbe_data3(binary(), binary() | nil, binary()) :: binary()
  def encode_tbe_data3(noc, icac, signature) do
    fields = %{
      1 => {:bytes, noc},
      3 => {:bytes, signature}
    }

    fields = if icac, do: Map.put(fields, 2, {:bytes, icac}), else: fields
    TLV.encode(fields)
  end

  @spec decode_tbe_data3(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_tbe_data3(data) do
    with {:ok, decoded} <- safe_decode(data),
         %{1 => noc, 3 => signature} <- decoded do
      {:ok, %{
        noc: noc,
        icac: Map.get(decoded, 2),
        signature: signature
      }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # ── NOC (Node Operational Certificate) ─────────────────────────

  @doc """
  Encode a simplified NOC containing node_id, fabric_id, and public_key.
  """
  @spec encode_noc(non_neg_integer(), non_neg_integer(), binary()) :: binary()
  def encode_noc(node_id, fabric_id, public_key) do
    TLV.encode(%{
      1 => {:uint, node_id},
      2 => {:uint, fabric_id},
      3 => {:bytes, public_key}
    })
  end

  @doc """
  Decode a NOC. Accepts both X.509 DER certificates (as sent by chip-tool)
  and the simplified TLV format used in internal tests.
  """
  @spec decode_noc(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_noc(<<0x30, _::binary>> = data) do
    decode_x509_noc(data)
  end

  def decode_noc(data) do
    decode_tlv_noc(data)
  end

  defp decode_tlv_noc(data) do
    with {:ok, decoded} <- safe_decode(data),
         %{1 => node_id, 2 => fabric_id, 3 => public_key} <- decoded do
      {:ok, %{node_id: node_id, fabric_id: fabric_id, public_key: public_key}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp decode_x509_noc(data) do
    cert = :public_key.der_decode(:Certificate, data)
    tbs = elem(cert, 1)

    # SubjectPublicKeyInfo is at index 7 in TBSCertificate record
    public_key = elem(tbs, 7) |> elem(2) |> normalize_bitstring()

    # Subject DN is at index 6 in TBSCertificate record
    {:rdnSequence, rdns} = elem(tbs, 6)
    node_id = find_matter_dn_attr(rdns, @matter_node_id_oid)
    fabric_id = find_matter_dn_attr(rdns, @matter_fabric_id_oid)

    if node_id && fabric_id && public_key do
      {:ok, %{node_id: node_id, fabric_id: fabric_id, public_key: public_key}}
    else
      {:error, :invalid_message}
    end
  rescue
    _ -> {:error, :invalid_message}
  end

  defp normalize_bitstring(bin) when is_binary(bin), do: bin

  defp normalize_bitstring(bits) when is_bitstring(bits) do
    size = bit_size(bits)

    if rem(size, 8) == 0 do
      bytes = div(size, 8)
      <<bin::binary-size(bytes)>> = bits
      bin
    end
  end

  defp normalize_bitstring(_), do: nil

  defp find_matter_dn_attr(rdns, target_oid) do
    Enum.find_value(rdns, fn rdn_set ->
      Enum.find_value(rdn_set, fn
        {:AttributeTypeAndValue, ^target_oid, value} ->
          parse_matter_dn_value(value)

        _ ->
          nil
      end)
    end)
  end

  # Erlang wraps unknown OID values in {:asn1_OPENTYPE, raw_der}
  defp parse_matter_dn_value({:asn1_OPENTYPE, raw_der}), do: parse_matter_dn_value(raw_der)

  # Raw DER UTF8String: tag 0x0C, length, hex string
  defp parse_matter_dn_value(<<0x0C, len, hex_str::binary-size(len)>>) when len < 128 do
    parse_hex_id(hex_str)
  end

  defp parse_matter_dn_value(<<0x0C, 0x81, len, hex_str::binary-size(len)>>) do
    parse_hex_id(hex_str)
  end

  # Erlang may decode as tagged tuple
  defp parse_matter_dn_value({:utf8String, str}), do: parse_hex_id(to_string(str))
  defp parse_matter_dn_value(_), do: nil

  defp parse_hex_id(hex_str) when is_binary(hex_str) do
    case Integer.parse(hex_str, 16) do
      {val, ""} -> val
      _ -> nil
    end
  end

  defp parse_hex_id(_), do: nil

  # ── Destination ID ──────────────────────────────────────────────

  @doc """
  Compute CASE destination identifier.

  `dest_id = HMAC-SHA256(IPK, initiator_random || node_id_le64 || fabric_id_le64)`
  """
  @spec compute_destination_id(binary(), binary(), non_neg_integer(), non_neg_integer()) :: binary()
  def compute_destination_id(ipk, initiator_random, node_id, fabric_id) do
    data = initiator_random <> <<node_id::little-64>> <> <<fabric_id::little-64>>
    :crypto.mac(:hmac, :sha256, ipk, data)
  end

  # ── TBE Encryption Helpers ─────────────────────────────────────

  @sigma2_nonce "NCASE_Sig2N\0\0"
  @sigma3_nonce "NCASE_Sig3N\0\0"

  @doc """
  Derive S2K or S3K from shared secret and IPK.
  """
  @spec derive_key(binary(), binary(), String.t()) :: binary()
  def derive_key(ipk, shared_secret, info) do
    KDF.hkdf(ipk, shared_secret, info, 16)
  end

  @doc """
  Encrypt TBE data with AES-128-CCM. Returns `ciphertext <> tag`.
  """
  @spec encrypt_tbe(:sigma2 | :sigma3, binary(), binary()) :: binary()
  def encrypt_tbe(which, key, plaintext) do
    nonce = tbe_nonce(which)
    {ciphertext, tag} = Session.encrypt(plaintext, key, nonce)
    ciphertext <> tag
  end

  @doc """
  Decrypt TBE data with AES-128-CCM.
  """
  @spec decrypt_tbe(:sigma2 | :sigma3, binary(), binary()) :: {:ok, binary()} | :error
  def decrypt_tbe(which, key, data) when byte_size(data) > 16 do
    nonce = tbe_nonce(which)
    ct_len = byte_size(data) - 16
    <<ciphertext::binary-size(ct_len), tag::binary-16>> = data
    Session.decrypt(ciphertext, tag, key, nonce)
  end

  def decrypt_tbe(_which, _key, _data), do: :error

  defp tbe_nonce(:sigma2), do: @sigma2_nonce
  defp tbe_nonce(:sigma3), do: @sigma3_nonce

  # ── Private ────────────────────────────────────────────────────

  defp safe_decode(data) do
    {:ok, TLV.decode(data)}
  rescue
    _ -> {:error, :invalid_message}
  end
end
