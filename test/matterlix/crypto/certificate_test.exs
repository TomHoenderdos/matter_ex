defmodule Matterlix.Crypto.CertificateTest do
  use ExUnit.Case, async: true

  alias Matterlix.Crypto.Certificate

  # ── Key Generation ──────────────────────────────────────────────

  describe "generate_keypair" do
    test "returns public and private key" do
      {pub, priv} = Certificate.generate_keypair()
      assert byte_size(pub) == 65
      assert <<0x04, _::binary>> = pub
      assert byte_size(priv) == 32
    end

    test "generates different keys each time" do
      {pub1, priv1} = Certificate.generate_keypair()
      {pub2, priv2} = Certificate.generate_keypair()
      assert pub1 != pub2
      assert priv1 != priv2
    end
  end

  # ── Sign / Verify Roundtrip ────────────────────────────────────

  describe "sign and verify" do
    test "signature verifies with correct key" do
      {pub, priv} = Certificate.generate_keypair()
      message = "hello matter"
      signature = Certificate.sign(message, priv)
      assert Certificate.verify(message, signature, pub)
    end

    test "empty message" do
      {pub, priv} = Certificate.generate_keypair()
      signature = Certificate.sign(<<>>, priv)
      assert Certificate.verify(<<>>, signature, pub)
    end

    test "large message" do
      {pub, priv} = Certificate.generate_keypair()
      message = :crypto.strong_rand_bytes(10_000)
      signature = Certificate.sign(message, priv)
      assert Certificate.verify(message, signature, pub)
    end

    test "binary data" do
      {pub, priv} = Certificate.generate_keypair()
      message = :crypto.strong_rand_bytes(256)
      signature = Certificate.sign(message, priv)
      assert Certificate.verify(message, signature, pub)
    end
  end

  # ── Verification Failures ──────────────────────────────────────

  describe "verification failures" do
    test "wrong public key" do
      {_pub1, priv1} = Certificate.generate_keypair()
      {pub2, _priv2} = Certificate.generate_keypair()
      signature = Certificate.sign("message", priv1)
      refute Certificate.verify("message", signature, pub2)
    end

    test "tampered message" do
      {pub, priv} = Certificate.generate_keypair()
      signature = Certificate.sign("original", priv)
      refute Certificate.verify("tampered", signature, pub)
    end

    test "tampered signature" do
      {pub, priv} = Certificate.generate_keypair()
      signature = Certificate.sign("message", priv)
      # Flip a byte in the signature
      <<first, rest::binary>> = signature
      tampered = <<first + 1, rest::binary>>
      refute Certificate.verify("message", tampered, pub)
    end
  end

  # ── Determinism ─────────────────────────────────────────────────

  describe "signature properties" do
    test "signatures are non-deterministic (different each time)" do
      {_pub, priv} = Certificate.generate_keypair()
      sig1 = Certificate.sign("same message", priv)
      sig2 = Certificate.sign("same message", priv)
      # ECDSA uses random k, so signatures differ
      assert sig1 != sig2
    end

    test "both signatures still verify" do
      {pub, priv} = Certificate.generate_keypair()
      sig1 = Certificate.sign("same message", priv)
      sig2 = Certificate.sign("same message", priv)
      assert Certificate.verify("same message", sig1, pub)
      assert Certificate.verify("same message", sig2, pub)
    end
  end
end
