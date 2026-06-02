defmodule MatterEx.CASE.Messages do
  @moduledoc """
  TLV codec for CASE Sigma protocol messages.

  Each message type has an encode and decode function.
  Encoding produces a TLV binary; decoding returns a plain map.
  """

  require Logger

  alias MatterEx.Crypto.{KDF, Session}
  alias MatterEx.TLV

  # Matter certificate DN OIDs
  @matter_node_id_oid {1, 3, 6, 1, 4, 1, 37244, 1, 1}
  @matter_fabric_id_oid {1, 3, 6, 1, 4, 1, 37244, 1, 5}
  @matter_case_authenticated_tag_oid {1, 3, 6, 1, 4, 1, 37244, 1, 22}

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
      {:ok,
       %{
         initiator_random: random,
         initiator_session_id: session_id,
         destination_id: dest_id,
         initiator_eph_pub: eph_pub,
         resumption_id: Map.get(decoded, 6),
         initiator_resume_mic: Map.get(decoded, 7)
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  # ── Sigma2 (opcode 0x31) ───────────────────────────────────────

  @spec encode_sigma2(binary(), non_neg_integer(), binary(), binary()) :: binary()
  def encode_sigma2(responder_random, session_id, eph_pub, encrypted2) do
    encode_sigma2(responder_random, session_id, eph_pub, encrypted2, nil)
  end

  @spec encode_sigma2(binary(), non_neg_integer(), binary(), binary(), map() | nil) :: binary()
  def encode_sigma2(responder_random, session_id, eph_pub, encrypted2, session_params) do
    fields = %{
      1 => {:bytes, responder_random},
      2 => {:uint, session_id},
      3 => {:bytes, eph_pub},
      4 => {:bytes, encrypted2}
    }

    fields =
      if session_params do
        Map.put(fields, 5, {:struct, session_params})
      else
        fields
      end

    TLV.encode(fields)
  end

  @spec decode_sigma2(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_sigma2(data) do
    with {:ok, decoded} <- safe_decode(data),
         %{1 => random, 2 => session_id, 3 => eph_pub, 4 => encrypted2} <- decoded do
      {:ok,
       %{
         responder_random: random,
         responder_session_id: session_id,
         responder_eph_pub: eph_pub,
         encrypted2: encrypted2,
         responder_session_params: Map.get(decoded, 5)
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  @doc """
  Default secure-channel session parameters.

  These mirror the fields emitted by connectedhomeip's PairingSession
  `EncodeSessionParameters`: MRP timings plus protocol revision hints.
  """
  @spec default_session_parameters() :: map()
  def default_session_parameters do
    %{
      # MRP idle retransmission interval, ms
      1 => {:uint32, 500},
      # MRP active retransmission interval, ms
      2 => {:uint32, 300},
      # MRP active threshold, ms
      3 => {:uint32, 4000},
      # Matter 1.3 / Apple Home current revisions
      4 => {:uint16, 19},
      5 => {:uint16, 12},
      6 => {:uint32, 0x01050000},
      7 => {:uint16, 1}
    }
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

    fields = put_optional_icac(fields, icac)
    TLV.encode(fields)
  end

  @spec decode_tbe_data2(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_tbe_data2(data) do
    with {:ok, decoded} <- safe_decode(data),
         %{1 => noc, 3 => signature, 4 => resumption_id} <- decoded do
      {:ok,
       %{
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

    fields = put_optional_icac(fields, icac)
    TLV.encode(fields)
  end

  @spec decode_tbe_data3(binary()) :: {:ok, map()} | {:error, :invalid_message}
  def decode_tbe_data3(data) do
    with {:ok, decoded} <- safe_decode(data),
         %{1 => noc, 3 => signature} <- decoded do
      {:ok,
       %{
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
  Extract the public key from an X.509 DER certificate.

  Returns the raw EC point (65 bytes for P-256 uncompressed) or nil.
  Works with any X.509 cert (root CA, ICAC, or NOC).
  """
  @spec extract_public_key(binary()) :: binary() | nil
  def extract_public_key(<<0x30, _::binary>> = data) do
    cert = :public_key.der_decode(:Certificate, data)
    tbs = elem(cert, 1)
    elem(tbs, 7) |> elem(2) |> normalize_bitstring()
  rescue
    _ -> nil
  end

  def extract_public_key(data) when is_binary(data) do
    # Try Matter TLV cert format: tag 9 = EllipticCurvePublicKey
    case safe_decode(data) do
      {:ok, %{9 => pubkey}} when is_binary(pubkey) -> pubkey
      _ -> nil
    end
  end

  def extract_public_key(_), do: nil

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
    with {:ok, decoded} when is_map(decoded) <- safe_decode(data) do
      cond do
        # Matter TLV cert format: tag 9 = public key, tag 6 = subject (nested map)
        # Subject DN: tag 17 = node_id, tag 21 = fabric_id, tag 22 = CASE Authenticated Tag
        Map.has_key?(decoded, 9) ->
          public_key = Map.get(decoded, 9)
          subject = Map.get(decoded, 6, %{})
          node_id = if is_map(subject), do: Map.get(subject, 17), else: 0
          fabric_id = if is_map(subject), do: Map.get(subject, 21), else: 0
          cats = if is_map(subject), do: normalize_cats(Map.get(subject, 22)), else: []

          {:ok,
           %{
             node_id: node_id || 0,
             fabric_id: fabric_id || 0,
             public_key: public_key,
             case_authenticated_tags: cats
           }}

        # Simple TLV format: tag 1 = node_id, tag 2 = fabric_id, tag 3 = public_key
        Map.has_key?(decoded, 3) ->
          {:ok,
           %{
             node_id: decoded[1],
             fabric_id: decoded[2],
             public_key: decoded[3],
             case_authenticated_tags: []
           }}

        true ->
          {:error, :invalid_message}
      end
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

    Logger.debug("decode_x509_noc: rdns=#{inspect(rdns, limit: :infinity)}")

    node_id = find_matter_dn_attr(rdns, @matter_node_id_oid)
    fabric_id = find_matter_dn_attr(rdns, @matter_fabric_id_oid)
    cats = find_matter_dn_attrs(rdns, @matter_case_authenticated_tag_oid)

    Logger.debug(
      "decode_x509_noc: node_id=#{inspect(node_id)} fabric_id=#{inspect(fabric_id)} cats=#{inspect(cats)} pub_key=#{if public_key, do: byte_size(public_key), else: "nil"}B"
    )

    if node_id && fabric_id && public_key do
      {:ok,
       %{
         node_id: node_id,
         fabric_id: fabric_id,
         public_key: public_key,
         case_authenticated_tags: cats
       }}
    else
      {:error, :invalid_message}
    end
  rescue
    e ->
      Logger.warning("decode_x509_noc rescue: #{inspect(e)}")
      {:error, :invalid_message}
  end

  defp normalize_cats(nil), do: []
  defp normalize_cats({:array, items}), do: normalize_cats(items)

  defp normalize_cats(items) when is_list(items) do
    items
    |> Enum.flat_map(&normalize_cats/1)
    |> Enum.uniq()
  end

  defp normalize_cats({:uint, value}) when is_integer(value), do: [value]
  defp normalize_cats(value) when is_integer(value), do: [value]
  defp normalize_cats(_), do: []

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

  defp find_matter_dn_attrs(rdns, target_oid) do
    rdns
    |> Enum.flat_map(fn rdn_set ->
      Enum.flat_map(rdn_set, fn
        {:AttributeTypeAndValue, ^target_oid, value} ->
          case parse_matter_dn_value(value) do
            nil -> []
            parsed -> [parsed]
          end

        _ ->
          []
      end)
    end)
    |> Enum.uniq()
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

  `dest_id = HMAC-SHA256(IPK, initiator_random || root_public_key || fabric_id_le64 || node_id_le64)`

  The root_public_key is the full 65-byte uncompressed EC point (including 0x04 prefix).
  """
  @spec compute_destination_id(binary(), binary(), binary(), non_neg_integer(), non_neg_integer()) ::
          binary()
  def compute_destination_id(ipk, initiator_random, root_public_key, fabric_id, node_id) do
    data =
      initiator_random <> root_public_key <> <<fabric_id::little-64>> <> <<node_id::little-64>>

    :crypto.mac(:hmac, :sha256, ipk, data)
  end

  # ── TBE Encryption Helpers ─────────────────────────────────────

  @sigma2_nonce "NCASE_Sigma2N"
  @sigma3_nonce "NCASE_Sigma3N"

  @doc """
  Derive S2K key for Sigma2 TBE encryption.

  Salt = IPK(16) || responder_random(32) || responder_eph_pub(65) || transcript_hash(32) = 145 bytes.
  The transcript_hash is SHA256 of sigma1 payload only.
  """
  @spec derive_sigma2_key(binary(), binary(), binary(), binary(), binary()) :: binary()
  def derive_sigma2_key(ipk, shared_secret, responder_random, responder_eph_pub, transcript_hash) do
    salt = ipk <> responder_random <> responder_eph_pub <> transcript_hash
    KDF.hkdf(salt, shared_secret, "Sigma2", 16)
  end

  @doc """
  Derive S3K key for Sigma3 TBE encryption.

  Salt = IPK(16) || transcript_hash(32) = 48 bytes.
  The transcript_hash is SHA256 of sigma1 || sigma2 payloads.
  """
  @spec derive_sigma3_key(binary(), binary(), binary()) :: binary()
  def derive_sigma3_key(ipk, shared_secret, transcript_hash) do
    salt = ipk <> transcript_hash
    KDF.hkdf(salt, shared_secret, "Sigma3", 16)
  end

  @doc """
  Build TBS (to-be-signed) data as a TLV structure.

  Matter CASE TBS contains:
  - Tag 1: Sender NOC certificate
  - Tag 2: Sender ICAC certificate (optional)
  - Tag 3: Sender ephemeral public key (65 bytes)
  - Tag 4: Receiver ephemeral public key (65 bytes)
  """
  @spec build_tbs(binary(), binary() | nil, binary(), binary()) :: binary()
  def build_tbs(noc, icac, sender_eph_pub, receiver_eph_pub) do
    fields = %{
      1 => {:bytes, noc},
      3 => {:bytes, sender_eph_pub},
      4 => {:bytes, receiver_eph_pub}
    }

    fields = put_optional_icac(fields, icac)
    TLV.encode(fields)
  end

  defp put_optional_icac(fields, icac) when is_binary(icac) and byte_size(icac) > 0,
    do: Map.put(fields, 2, {:bytes, icac})

  defp put_optional_icac(fields, _icac), do: fields

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
