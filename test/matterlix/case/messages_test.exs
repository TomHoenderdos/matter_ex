defmodule Matterlix.CASE.MessagesTest do
  use ExUnit.Case, async: true

  alias Matterlix.CASE.Messages
  alias Matterlix.Crypto.Certificate

  @ipk :crypto.strong_rand_bytes(16)

  describe "Sigma1 encode/decode" do
    test "round-trip" do
      random = :crypto.strong_rand_bytes(32)
      session_id = 42
      dest_id = :crypto.strong_rand_bytes(32)
      {eph_pub, _priv} = Certificate.generate_keypair()

      encoded = Messages.encode_sigma1(random, session_id, dest_id, eph_pub)
      assert {:ok, decoded} = Messages.decode_sigma1(encoded)

      assert decoded.initiator_random == random
      assert decoded.initiator_session_id == session_id
      assert decoded.destination_id == dest_id
      assert decoded.initiator_eph_pub == eph_pub
    end

    test "invalid data returns error" do
      assert {:error, :invalid_message} = Messages.decode_sigma1(<<0>>)
    end
  end

  describe "Sigma2 encode/decode" do
    test "round-trip" do
      random = :crypto.strong_rand_bytes(32)
      session_id = 99
      {eph_pub, _priv} = Certificate.generate_keypair()
      encrypted2 = :crypto.strong_rand_bytes(64)

      encoded = Messages.encode_sigma2(random, session_id, eph_pub, encrypted2)
      assert {:ok, decoded} = Messages.decode_sigma2(encoded)

      assert decoded.responder_random == random
      assert decoded.responder_session_id == session_id
      assert decoded.responder_eph_pub == eph_pub
      assert decoded.encrypted2 == encrypted2
    end
  end

  describe "Sigma3 encode/decode" do
    test "round-trip" do
      encrypted3 = :crypto.strong_rand_bytes(80)

      encoded = Messages.encode_sigma3(encrypted3)
      assert {:ok, decoded} = Messages.decode_sigma3(encoded)

      assert decoded.encrypted3 == encrypted3
    end

    test "invalid data returns error" do
      assert {:error, :invalid_message} = Messages.decode_sigma3(<<0>>)
    end
  end

  describe "TBEData2 encode/decode" do
    test "round-trip with ICAC" do
      noc = :crypto.strong_rand_bytes(100)
      icac = :crypto.strong_rand_bytes(80)
      signature = :crypto.strong_rand_bytes(64)
      resumption_id = :crypto.strong_rand_bytes(16)

      encoded = Messages.encode_tbe_data2(noc, icac, signature, resumption_id)
      assert {:ok, decoded} = Messages.decode_tbe_data2(encoded)

      assert decoded.noc == noc
      assert decoded.icac == icac
      assert decoded.signature == signature
      assert decoded.resumption_id == resumption_id
    end

    test "round-trip without ICAC" do
      noc = :crypto.strong_rand_bytes(100)
      signature = :crypto.strong_rand_bytes(64)
      resumption_id = :crypto.strong_rand_bytes(16)

      encoded = Messages.encode_tbe_data2(noc, nil, signature, resumption_id)
      assert {:ok, decoded} = Messages.decode_tbe_data2(encoded)

      assert decoded.noc == noc
      assert decoded.icac == nil
      assert decoded.signature == signature
      assert decoded.resumption_id == resumption_id
    end
  end

  describe "TBEData3 encode/decode" do
    test "round-trip with ICAC" do
      noc = :crypto.strong_rand_bytes(100)
      icac = :crypto.strong_rand_bytes(80)
      signature = :crypto.strong_rand_bytes(64)

      encoded = Messages.encode_tbe_data3(noc, icac, signature)
      assert {:ok, decoded} = Messages.decode_tbe_data3(encoded)

      assert decoded.noc == noc
      assert decoded.icac == icac
      assert decoded.signature == signature
    end

    test "round-trip without ICAC" do
      noc = :crypto.strong_rand_bytes(100)
      signature = :crypto.strong_rand_bytes(64)

      encoded = Messages.encode_tbe_data3(noc, nil, signature)
      assert {:ok, decoded} = Messages.decode_tbe_data3(encoded)

      assert decoded.noc == noc
      assert decoded.icac == nil
      assert decoded.signature == signature
    end
  end

  describe "NOC encode/decode" do
    test "simplified TLV round-trip" do
      {pub, _priv} = Certificate.generate_keypair()
      node_id = 12345
      fabric_id = 1

      encoded = Messages.encode_noc(node_id, fabric_id, pub)
      assert {:ok, decoded} = Messages.decode_noc(encoded)

      assert decoded.node_id == node_id
      assert decoded.fabric_id == fabric_id
      assert decoded.public_key == pub
    end

    test "X.509 DER NOC extracts node_id, fabric_id, and public_key" do
      {pub, _priv} = Certificate.generate_keypair()
      node_id = 1
      fabric_id = 1

      der = build_x509_noc(pub, node_id, fabric_id)
      assert {:ok, decoded} = Messages.decode_noc(der)

      assert decoded.node_id == node_id
      assert decoded.fabric_id == fabric_id
      assert decoded.public_key == pub
    end

    test "X.509 DER NOC with large IDs" do
      {pub, _priv} = Certificate.generate_keypair()
      node_id = 0xABCD1234DEAD5678
      fabric_id = 0x0000000100000002

      der = build_x509_noc(pub, node_id, fabric_id)
      assert {:ok, decoded} = Messages.decode_noc(der)

      assert decoded.node_id == node_id
      assert decoded.fabric_id == fabric_id
      assert decoded.public_key == pub
    end

    test "X.509 DER NOC is parseable by :public_key.der_decode" do
      {pub, _priv} = Certificate.generate_keypair()
      der = build_x509_noc(pub, 1, 1)

      # Verify our test cert is valid DER
      assert {:Certificate, _tbs, _algo, _sig} = :public_key.der_decode(:Certificate, der)
    end

    test "extract_public_key from X.509 DER cert" do
      {pub, _priv} = Certificate.generate_keypair()
      der = build_x509_noc(pub, 1, 1)

      assert Messages.extract_public_key(der) == pub
    end

    test "extract_public_key returns nil for non-DER" do
      assert Messages.extract_public_key(<<0x01, 0x02>>) == nil
    end

    test "invalid DER starting with 0x30 returns error" do
      assert {:error, :invalid_message} = Messages.decode_noc(<<0x30, 0x00>>)
    end

    test "invalid data returns error" do
      assert {:error, :invalid_message} = Messages.decode_noc(<<0>>)
    end
  end

  describe "destination_id" do
    test "deterministic computation" do
      random = :crypto.strong_rand_bytes(32)
      node_id = 1
      fabric_id = 1

      id1 = Messages.compute_destination_id(@ipk, random, node_id, fabric_id)
      id2 = Messages.compute_destination_id(@ipk, random, node_id, fabric_id)

      assert id1 == id2
      assert byte_size(id1) == 32
    end

    test "different IPK produces different dest_id" do
      random = :crypto.strong_rand_bytes(32)
      ipk2 = :crypto.strong_rand_bytes(16)

      id1 = Messages.compute_destination_id(@ipk, random, 1, 1)
      id2 = Messages.compute_destination_id(ipk2, random, 1, 1)

      assert id1 != id2
    end
  end

  describe "TBE encrypt/decrypt" do
    test "sigma2 round-trip" do
      key = :crypto.strong_rand_bytes(16)
      plaintext = "hello TBE sigma2"

      encrypted = Messages.encrypt_tbe(:sigma2, key, plaintext)
      assert {:ok, ^plaintext} = Messages.decrypt_tbe(:sigma2, key, encrypted)
    end

    test "sigma3 round-trip" do
      key = :crypto.strong_rand_bytes(16)
      plaintext = "hello TBE sigma3"

      encrypted = Messages.encrypt_tbe(:sigma3, key, plaintext)
      assert {:ok, ^plaintext} = Messages.decrypt_tbe(:sigma3, key, encrypted)
    end

    test "wrong key fails decryption" do
      key = :crypto.strong_rand_bytes(16)
      wrong_key = :crypto.strong_rand_bytes(16)
      plaintext = "secret"

      encrypted = Messages.encrypt_tbe(:sigma2, key, plaintext)
      assert :error = Messages.decrypt_tbe(:sigma2, wrong_key, encrypted)
    end

    test "sigma2 key cannot decrypt sigma3 data" do
      key = :crypto.strong_rand_bytes(16)
      plaintext = "nonce matters"

      encrypted = Messages.encrypt_tbe(:sigma2, key, plaintext)
      assert :error = Messages.decrypt_tbe(:sigma3, key, encrypted)
    end

    test "derive_key produces 16-byte key" do
      shared_secret = :crypto.strong_rand_bytes(32)
      key = Messages.derive_key(@ipk, shared_secret, "Sigma2")
      assert byte_size(key) == 16
    end
  end

  # ── X.509 DER test cert builder ──────────────────────────────────

  # Pre-encoded OID bytes
  @oid_ecdsa_sha256 <<0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02>>
  @oid_ec_pubkey <<0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01>>
  @oid_prime256v1 <<0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07>>
  @oid_matter_node_id <<0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0xA2, 0x7C, 0x01, 0x01>>
  @oid_matter_fabric_id <<0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0xA2, 0x7C, 0x01, 0x05>>

  defp build_x509_noc(public_key, node_id, fabric_id) do
    node_hex = node_id |> Integer.to_string(16) |> String.pad_leading(16, "0")
    fabric_hex = fabric_id |> Integer.to_string(16) |> String.pad_leading(16, "0")

    sig_algo = der_seq(der_oid(@oid_ecdsa_sha256))

    issuer = der_seq(
      der_set(der_seq(der_oid(<<0x55, 0x04, 0x03>>) <> der_utf8("Test CA")))
    )

    validity = der_seq(
      der_utctime("250101000000Z") <> der_utctime("350101000000Z")
    )

    subject = der_seq(
      der_set(der_seq(der_oid(@oid_matter_node_id) <> der_utf8(node_hex))) <>
      der_set(der_seq(der_oid(@oid_matter_fabric_id) <> der_utf8(fabric_hex)))
    )

    spki = der_seq(
      der_seq(der_oid(@oid_ec_pubkey) <> der_oid(@oid_prime256v1)) <>
      der_bitstring(public_key)
    )

    tbs = der_seq(
      der_explicit(0, der_int(2)) <>
      der_int(1) <>
      sig_algo <>
      issuer <>
      validity <>
      subject <>
      spki
    )

    # Fake signature (not validated during NOC parsing)
    fake_sig = :crypto.strong_rand_bytes(64)

    der_seq(tbs <> sig_algo <> der_bitstring(fake_sig))
  end

  defp der_tlv(tag, value) do
    len = byte_size(value)

    length_bytes =
      cond do
        len < 128 -> <<len>>
        len < 256 -> <<0x81, len>>
        true -> <<0x82, len::16>>
      end

    <<tag>> <> length_bytes <> value
  end

  defp der_seq(content), do: der_tlv(0x30, content)
  defp der_set(content), do: der_tlv(0x31, content)
  defp der_oid(bytes), do: der_tlv(0x06, bytes)
  defp der_utf8(str), do: der_tlv(0x0C, str)
  defp der_bitstring(bytes), do: der_tlv(0x03, <<0>> <> bytes)
  defp der_utctime(str), do: der_tlv(0x17, str)
  defp der_explicit(tag_num, content), do: der_tlv(0xA0 + tag_num, content)

  defp der_int(n) when n >= 0 do
    bytes = :binary.encode_unsigned(n)
    # Ensure positive by adding leading zero if high bit set
    bytes = if :binary.first(bytes) >= 128, do: <<0>> <> bytes, else: bytes
    der_tlv(0x02, bytes)
  end
end
