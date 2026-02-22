defmodule MatterEx.Crypto.P256Test do
  use ExUnit.Case, async: true

  alias MatterEx.Crypto.P256

  # ── Generator Point ─────────────────────────────────────────────

  describe "generator" do
    test "generator is on curve" do
      assert P256.on_curve?(P256.generator())
    end

    test "1 * G == G" do
      g = P256.generator()
      assert P256.multiply(1, g) == g
    end

    test "2 * G == G + G" do
      g = P256.generator()
      assert P256.multiply(2, g) == P256.add(g, g)
    end

    test "n * G == infinity (curve order)" do
      g = P256.generator()
      assert P256.multiply(P256.n(), g) == :infinity
    end
  end

  # ── Cross-check with :crypto ────────────────────────────────────

  describe "cross-check with :crypto" do
    test "scalar * G matches :crypto.generate_key" do
      # Use a known scalar
      scalar = :crypto.strong_rand_bytes(32) |> :binary.decode_unsigned(:big)
      scalar = rem(scalar, P256.n() - 1) + 1

      # Our implementation
      {x, y} = P256.multiply(scalar, P256.generator())
      our_point = <<0x04, x::unsigned-big-256, y::unsigned-big-256>>

      # :crypto implementation
      {crypto_point, _priv} =
        :crypto.generate_key(:ecdh, :secp256r1, scalar)

      assert our_point == crypto_point
    end

    test "multiple random scalars match :crypto" do
      for _ <- 1..3 do
        scalar = :crypto.strong_rand_bytes(32) |> :binary.decode_unsigned(:big)
        scalar = rem(scalar, P256.n() - 1) + 1

        {x, y} = P256.multiply(scalar, P256.generator())
        our_point = <<0x04, x::unsigned-big-256, y::unsigned-big-256>>

        {crypto_point, _} = :crypto.generate_key(:ecdh, :secp256r1, scalar)
        assert our_point == crypto_point
      end
    end
  end

  # ── Point Arithmetic Properties ─────────────────────────────────

  describe "point arithmetic" do
    test "commutativity: P + Q == Q + P" do
      g = P256.generator()
      p = P256.multiply(7, g)
      q = P256.multiply(13, g)
      assert P256.add(p, q) == P256.add(q, p)
    end

    test "associativity: (P + Q) + R == P + (Q + R)" do
      g = P256.generator()
      p = P256.multiply(3, g)
      q = P256.multiply(5, g)
      r = P256.multiply(11, g)
      assert P256.add(P256.add(p, q), r) == P256.add(p, P256.add(q, r))
    end

    test "distributivity: (a + b) * G == a*G + b*G" do
      g = P256.generator()
      a = 12345
      b = 67890
      lhs = P256.multiply(a + b, g)
      rhs = P256.add(P256.multiply(a, g), P256.multiply(b, g))
      assert lhs == rhs
    end

    test "P + (-P) == infinity" do
      g = P256.generator()
      p = P256.multiply(42, g)
      neg_p = P256.negate(p)
      assert P256.add(p, neg_p) == :infinity
    end

    test "P + infinity == P" do
      g = P256.generator()
      p = P256.multiply(99, g)
      assert P256.add(p, :infinity) == p
      assert P256.add(:infinity, p) == p
    end

    test "multiply by 0 gives infinity" do
      assert P256.multiply(0, P256.generator()) == :infinity
    end

    test "double is same as add to self" do
      g = P256.generator()
      p = P256.multiply(17, g)
      assert P256.double(p) == P256.add(p, p)
    end
  end

  # ── Encoding/Decoding ──────────────────────────────────────────

  describe "encoding" do
    test "encode/decode roundtrip" do
      g = P256.generator()
      p = P256.multiply(42, g)
      encoded = P256.encode_point(p)
      assert byte_size(encoded) == 65
      assert <<0x04, _::binary>> = encoded
      assert P256.decode_point(encoded) == p
    end

    test "encode infinity" do
      assert P256.encode_point(:infinity) == <<0x00>>
    end
  end

  # ── On-curve Validation ─────────────────────────────────────────

  describe "on_curve?" do
    test "valid points are on curve" do
      g = P256.generator()

      for scalar <- [1, 2, 42, 1000, 999_999] do
        point = P256.multiply(scalar, g)
        assert P256.on_curve?(point), "#{scalar} * G should be on curve"
      end
    end

    test "infinity is on curve" do
      assert P256.on_curve?(:infinity)
    end

    test "invalid point is not on curve" do
      refute P256.on_curve?({1, 2})
    end
  end

  # ── scalar_mod_n ────────────────────────────────────────────────

  describe "scalar_mod_n" do
    test "reduces binary to scalar mod n" do
      # 40 bytes (320 bits) — larger than n (256 bits)
      big_binary = :crypto.strong_rand_bytes(40)
      scalar = P256.scalar_mod_n(big_binary)
      assert scalar >= 0
      assert scalar < P256.n()
    end

    test "small value unchanged" do
      binary = <<42::unsigned-big-256>>
      assert P256.scalar_mod_n(binary) == 42
    end
  end
end
