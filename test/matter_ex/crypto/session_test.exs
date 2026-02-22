defmodule MatterEx.Crypto.SessionTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias MatterEx.Crypto.Session

  defp random_key, do: :crypto.strong_rand_bytes(16)
  defp random_nonce, do: :crypto.strong_rand_bytes(13)

  # ── Roundtrip Tests ───────────────────────────────────────────────

  describe "encrypt/decrypt roundtrip" do
    test "empty plaintext" do
      key = random_key()
      nonce = random_nonce()
      {ct, tag} = Session.encrypt(<<>>, key, nonce)
      assert {:ok, <<>>} = Session.decrypt(ct, tag, key, nonce)
    end

    test "short plaintext" do
      key = random_key()
      nonce = random_nonce()
      {ct, tag} = Session.encrypt("hello matter", key, nonce)
      assert {:ok, "hello matter"} = Session.decrypt(ct, tag, key, nonce)
    end

    test "256-byte plaintext" do
      key = random_key()
      nonce = random_nonce()
      plaintext = :crypto.strong_rand_bytes(256)
      {ct, tag} = Session.encrypt(plaintext, key, nonce)
      assert {:ok, ^plaintext} = Session.decrypt(ct, tag, key, nonce)
    end

    test "with AAD" do
      key = random_key()
      nonce = random_nonce()
      aad = "additional data"
      {ct, tag} = Session.encrypt("payload", key, nonce, aad)
      assert {:ok, "payload"} = Session.decrypt(ct, tag, key, nonce, aad)
    end

    test "1024-byte plaintext with AAD" do
      key = random_key()
      nonce = random_nonce()
      plaintext = :crypto.strong_rand_bytes(1024)
      aad = :crypto.strong_rand_bytes(64)
      {ct, tag} = Session.encrypt(plaintext, key, nonce, aad)
      assert {:ok, ^plaintext} = Session.decrypt(ct, tag, key, nonce, aad)
    end
  end

  # ── Tag Properties ────────────────────────────────────────────────

  describe "tag properties" do
    test "tag is 16 bytes" do
      key = random_key()
      nonce = random_nonce()
      {_ct, tag} = Session.encrypt("data", key, nonce)
      assert byte_size(tag) == 16
    end

    test "ciphertext same length as plaintext" do
      key = random_key()
      nonce = random_nonce()
      plaintext = "exactly 32 bytes of test input!!"
      {ct, _tag} = Session.encrypt(plaintext, key, nonce)
      assert byte_size(ct) == byte_size(plaintext)
    end
  end

  # ── Tamper Detection ──────────────────────────────────────────────

  describe "tamper detection" do
    test "wrong key fails" do
      key1 = random_key()
      key2 = random_key()
      nonce = random_nonce()
      {ct, tag} = Session.encrypt("secret", key1, nonce)
      assert :error = Session.decrypt(ct, tag, key2, nonce)
    end

    test "wrong nonce fails" do
      key = random_key()
      nonce1 = random_nonce()
      nonce2 = random_nonce()
      {ct, tag} = Session.encrypt("secret", key, nonce1)
      assert :error = Session.decrypt(ct, tag, key, nonce2)
    end

    test "wrong AAD fails" do
      key = random_key()
      nonce = random_nonce()
      {ct, tag} = Session.encrypt("secret", key, nonce, "aad1")
      assert :error = Session.decrypt(ct, tag, key, nonce, "aad2")
    end

    test "missing AAD fails" do
      key = random_key()
      nonce = random_nonce()
      {ct, tag} = Session.encrypt("secret", key, nonce, "some aad")
      assert :error = Session.decrypt(ct, tag, key, nonce)
    end

    test "tampered ciphertext fails" do
      key = random_key()
      nonce = random_nonce()
      {ct, tag} = Session.encrypt("secret", key, nonce)
      <<first, rest::binary>> = ct
      tampered = <<bxor(first, 0xFF), rest::binary>>
      assert :error = Session.decrypt(tampered, tag, key, nonce)
    end

    test "tampered tag fails" do
      key = random_key()
      nonce = random_nonce()
      {ct, tag} = Session.encrypt("secret", key, nonce)
      <<first, rest::binary>> = tag
      tampered_tag = <<bxor(first, 0xFF), rest::binary>>
      assert :error = Session.decrypt(ct, tampered_tag, key, nonce)
    end
  end

  # ── Known Vector ──────────────────────────────────────────────────

  describe "deterministic" do
    test "same inputs produce same output" do
      key = :binary.copy(<<0xAB>>, 16)
      nonce = :binary.copy(<<0xCD>>, 13)
      {ct1, tag1} = Session.encrypt("test", key, nonce)
      {ct2, tag2} = Session.encrypt("test", key, nonce)
      assert ct1 == ct2
      assert tag1 == tag2
    end

    test "different plaintexts produce different ciphertext" do
      key = random_key()
      nonce = random_nonce()
      {ct1, _} = Session.encrypt("message1", key, nonce)
      {ct2, _} = Session.encrypt("message2", key, nonce)
      assert ct1 != ct2
    end
  end
end
