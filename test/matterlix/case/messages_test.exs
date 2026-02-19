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
    test "round-trip" do
      {pub, _priv} = Certificate.generate_keypair()
      node_id = 12345
      fabric_id = 1

      encoded = Messages.encode_noc(node_id, fabric_id, pub)
      assert {:ok, decoded} = Messages.decode_noc(encoded)

      assert decoded.node_id == node_id
      assert decoded.fabric_id == fabric_id
      assert decoded.public_key == pub
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
end
