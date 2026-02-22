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
  Sign a message with ECDSA-SHA256 over P-256.

  Returns the raw P1363 format signature (r || s, 64 bytes).
  Matter uses this format for attestation and NOCSR signatures.
  """
  @spec sign_raw(binary(), binary()) :: binary()
  def sign_raw(message, private_key) do
    der = sign(message, private_key)
    der_signature_to_raw(der)
  end

  @doc """
  Convert a DER-encoded ECDSA signature to raw P1363 format (r || s).

  For P-256, the output is always exactly 64 bytes.
  """
  @spec der_signature_to_raw(binary()) :: binary()
  def der_signature_to_raw(<<0x30, _len, 0x02, r_len, rest::binary>>) do
    <<r_bytes::binary-size(r_len), 0x02, s_len, s_rest::binary>> = rest
    <<s_bytes::binary-size(s_len), _::binary>> = s_rest
    pad_to_32(r_bytes) <> pad_to_32(s_bytes)
  end

  defp pad_to_32(bytes) when byte_size(bytes) > 32 do
    # Strip leading zero padding (DER adds 0x00 for high-bit values)
    binary_part(bytes, byte_size(bytes) - 32, 32)
  end

  defp pad_to_32(bytes) when byte_size(bytes) < 32 do
    :binary.copy(<<0>>, 32 - byte_size(bytes)) <> bytes
  end

  defp pad_to_32(bytes), do: bytes

  @doc """
  Verify an ECDSA-SHA256 signature over P-256 (DER-encoded signature).
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(message, signature, public_key) do
    :crypto.verify(:ecdsa, :sha256, message, signature, [public_key, @curve])
  end

  @doc """
  Verify an ECDSA-SHA256 signature in raw P1363 format (r || s, 64 bytes).

  Matter CASE uses raw format. Converts to DER for Erlang's crypto module.
  """
  @spec verify_raw(binary(), binary(), binary()) :: boolean()
  def verify_raw(message, signature, public_key) when byte_size(signature) == 64 do
    der_sig = raw_signature_to_der(signature)
    verify(message, der_sig, public_key)
  end

  def verify_raw(message, signature, public_key) do
    # Assume DER format if not 64 bytes
    verify(message, signature, public_key)
  end

  @doc """
  Convert a raw P1363 signature (r || s, 64 bytes) to DER format.
  """
  @spec raw_signature_to_der(binary()) :: binary()
  def raw_signature_to_der(<<r::binary-32, s::binary-32>>) do
    r_enc = encode_asn1_integer(r)
    s_enc = encode_asn1_integer(s)
    inner = r_enc <> s_enc
    <<0x30, byte_size(inner)>> <> inner
  end

  defp encode_asn1_integer(bytes) do
    trimmed = trim_leading_zeros(bytes)
    padded = if :binary.at(trimmed, 0) >= 0x80, do: <<0x00, trimmed::binary>>, else: trimmed
    <<0x02, byte_size(padded), padded::binary>>
  end

  defp trim_leading_zeros(<<0, rest::binary>>) when byte_size(rest) > 0, do: trim_leading_zeros(rest)
  defp trim_leading_zeros(bytes), do: bytes

  @doc """
  Compute ECDH shared secret (P-256 x-coordinate, 32 bytes).
  """
  @spec ecdh(binary(), binary()) :: binary()
  def ecdh(peer_public_key, my_private_key) do
    :crypto.compute_key(:ecdh, peer_public_key, my_private_key, @curve)
  end

  @doc """
  Extract the EC public key from a PKCS#10 CSR DER.

  Returns the 65-byte uncompressed SEC1 point (0x04 || x || y).
  """
  @spec pubkey_from_csr(binary()) :: binary()
  def pubkey_from_csr(csr_der) do
    # Parse: SEQUENCE { CertReqInfo, ... }
    #   CertReqInfo: SEQUENCE { version, subject, SPKI, attrs }
    #     SPKI: SEQUENCE { AlgoId, BIT STRING(pubkey) }
    <<0x30, _::binary>> = csr_der
    {cert_req_info, _rest} = der_parse_element(csr_der)
    {inner, _} = der_parse_element(cert_req_info)
    # Skip version (INTEGER) and subject (SEQUENCE)
    {_version, after_version} = der_skip_element(inner)
    {_subject, after_subject} = der_skip_element(after_version)
    # SPKI
    {spki, _} = der_parse_element(after_subject)
    # Skip AlgorithmIdentifier
    {_algo, after_algo} = der_skip_element(spki)
    # BIT STRING containing public key
    <<0x03, _::binary>> = after_algo
    {bit_content, _} = der_parse_element(after_algo)
    # Strip unused-bits byte (0x00)
    <<0x00, pubkey::binary>> = bit_content
    pubkey
  end

  defp der_parse_element(<<tag, rest::binary>>) when tag in [0x30, 0x31] do
    {len, content_start} = der_read_length(rest)
    <<content::binary-size(len), remaining::binary>> = content_start
    {content, remaining}
  end

  defp der_parse_element(<<_tag, rest::binary>>) do
    {len, content_start} = der_read_length(rest)
    <<content::binary-size(len), remaining::binary>> = content_start
    {content, remaining}
  end

  defp der_skip_element(<<_tag, rest::binary>>) do
    {len, content_start} = der_read_length(rest)
    <<_content::binary-size(len), remaining::binary>> = content_start
    {nil, remaining}
  end

  defp der_read_length(<<len, rest::binary>>) when len < 128, do: {len, rest}
  defp der_read_length(<<0x81, len, rest::binary>>), do: {len, rest}
  defp der_read_length(<<0x82, len::16, rest::binary>>), do: {len, rest}

  @doc """
  Build a minimal PKCS#10 Certificate Signing Request (CSR) in DER format.

  Used during commissioning when chip-tool sends CSRRequest.
  The CSR contains the EC public key and is signed with the private key.
  """
  @spec build_csr(binary(), binary()) :: binary()
  def build_csr(pub, priv) when is_binary(pub) and is_binary(priv) do
    # OIDs
    ecdsa_sha256 = <<0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02>>
    ec_pubkey = <<0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01>>
    prime256v1 = <<0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07>>
    der_null = <<0x05, 0x00>>

    # AlgorithmIdentifier: SEQUENCE { OID, NULL } — BoringSSL requires NULL param
    algorithm = der_seq(ecdsa_sha256 <> der_null)
    pub_key_algorithm = der_seq(ec_pubkey <> prime256v1)

    # CertificationRequestInfo
    version = <<0x02, 0x01, 0x00>>  # INTEGER 0
    subject = der_seq(<<>>)  # empty subject (Matter spec)
    spki = der_seq(pub_key_algorithm <> der_bit_string(pub))
    attributes = <<0xA0, 0x00>>  # [0] IMPLICIT SET OF Attribute, empty

    cert_req_info = der_seq(version <> subject <> spki <> attributes)

    # Sign the CertificationRequestInfo
    sig = :crypto.sign(:ecdsa, :sha256, cert_req_info, [priv, @curve])

    # CertificationRequest = SEQUENCE { certReqInfo, algorithm, signature }
    der_seq(cert_req_info <> algorithm <> der_bit_string(sig))
  end

  @doc """
  Build a minimal self-signed X.509 DER certificate.

  Used during commissioning when chip-tool requests PAI/DAC certificates.
  With --bypass-attestation-verifier, chip-tool won't validate the content.
  """
  @spec self_signed_der(binary(), binary(), String.t()) :: binary()
  def self_signed_der(pub, priv, cn) when is_binary(pub) and is_binary(priv) do
    # OIDs
    ecdsa_sha256 = <<0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02>>
    ec_pubkey = <<0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01>>
    prime256v1 = <<0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07>>

    algorithm = der_seq(ecdsa_sha256)
    pub_key_algorithm = der_seq(ec_pubkey <> prime256v1)
    cn_bytes = cn |> to_string()

    # Subject/Issuer: SEQUENCE { SET { SEQUENCE { OID(CN), UTF8String(cn) } } }
    # X.509 Name = SEQUENCE OF RelativeDistinguishedName
    # RelativeDistinguishedName = SET OF AttributeTypeAndValue
    cn_oid = <<0x06, 0x03, 0x55, 0x04, 0x03>>
    cn_str = <<0x0C, byte_size(cn_bytes)>> <> cn_bytes
    name = der_seq(der_set(der_seq(cn_oid <> cn_str)))

    # Validity: 2020-01-01 to 2040-01-01
    not_before = <<0x17, 13>> <> "200101000000Z"
    not_after = <<0x17, 13>> <> "400101000000Z"
    validity = der_seq(not_before <> not_after)

    # SubjectPublicKeyInfo
    spki = der_seq(pub_key_algorithm <> der_bit_string(pub))

    # Version [0] EXPLICIT v3(2)
    version = <<0xA0, 3, 0x02, 1, 2>>

    # Serial number
    serial = <<0x02, 1, 1>>

    # TBSCertificate
    tbs = der_seq(version <> serial <> algorithm <> name <> validity <> name <> spki)

    # Sign
    sig = :crypto.sign(:ecdsa, :sha256, tbs, [priv, @curve])

    # Certificate = SEQUENCE { tbs, algorithm, signature }
    der_seq(tbs <> algorithm <> der_bit_string(sig))
  end

  defp der_seq(content) do
    <<0x30>> <> der_length(byte_size(content)) <> content
  end

  defp der_set(content) do
    <<0x31>> <> der_length(byte_size(content)) <> content
  end

  defp der_bit_string(content) do
    inner = <<0x00>> <> content
    <<0x03>> <> der_length(byte_size(inner)) <> inner
  end

  defp der_length(len) when len < 128, do: <<len>>
  defp der_length(len) when len < 256, do: <<0x81, len>>
  defp der_length(len), do: <<0x82, len::16>>
end
