defmodule Matterlix.Crypto.P256 do
  @moduledoc false
  # Pure Elixir P-256 (secp256r1) elliptic curve point arithmetic.
  #
  # OTP's :crypto only exposes high-level ECDH/ECDSA, not raw EC point
  # operations. SPAKE2+ requires scalar multiply and point add on arbitrary
  # points, so we implement affine coordinate math here.
  #
  # This is acceptable because commissioning is not a hot path.

  # Curve parameters (NIST P-256 / secp256r1)
  @p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @a @p - 3
  @b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
  @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @gx 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
  @gy 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5

  def p, do: @p
  def n, do: @n
  def generator, do: {@gx, @gy}

  # ── Point Operations ────────────────────────────────────────────

  @doc false
  def add(:infinity, point), do: point
  def add(point, :infinity), do: point

  def add({x1, y1}, {x2, y2}) when x1 == x2 and y1 == y2 do
    double({x1, y1})
  end

  def add({x1, _y1}, {x2, _y2}) when x1 == x2 do
    # Points are inverses of each other
    :infinity
  end

  def add({x1, y1}, {x2, y2}) do
    # lambda = (y2 - y1) / (x2 - x1) mod p
    lambda = mod((y2 - y1) * mod_inv(mod(x2 - x1, @p), @p), @p)
    x3 = mod(lambda * lambda - x1 - x2, @p)
    y3 = mod(lambda * (x1 - x3) - y1, @p)
    {x3, y3}
  end

  @doc false
  def double(:infinity), do: :infinity

  def double({_x, y}) when y == 0, do: :infinity

  def double({x, y}) do
    # lambda = (3*x^2 + a) / (2*y) mod p
    lambda = mod((3 * x * x + @a) * mod_inv(mod(2 * y, @p), @p), @p)
    x3 = mod(lambda * lambda - 2 * x, @p)
    y3 = mod(lambda * (x - x3) - y, @p)
    {x3, y3}
  end

  @doc false
  def multiply(_scalar, :infinity), do: :infinity
  def multiply(0, _point), do: :infinity

  def multiply(scalar, point) when scalar < 0 do
    multiply(mod(scalar, @n), point)
  end

  def multiply(scalar, point) do
    # Double-and-add (left-to-right)
    bits = Integer.digits(scalar, 2)

    Enum.reduce(tl(bits), point, fn bit, acc ->
      doubled = double(acc)
      if bit == 1, do: add(doubled, point), else: doubled
    end)
  end

  @doc false
  def negate(:infinity), do: :infinity
  def negate({x, y}), do: {x, mod(-y, @p)}

  # ── Encoding / Decoding ─────────────────────────────────────────

  @doc false
  def encode_point(:infinity), do: <<0x00>>

  def encode_point({x, y}) do
    <<0x04, x::unsigned-big-256, y::unsigned-big-256>>
  end

  @doc false
  def decode_point(<<0x04, x::unsigned-big-256, y::unsigned-big-256>>) do
    {x, y}
  end

  # ── Validation ──────────────────────────────────────────────────

  @doc false
  def on_curve?(:infinity), do: true

  def on_curve?({x, y}) do
    lhs = mod(y * y, @p)
    rhs = mod(x * x * x + @a * x + @b, @p)
    lhs == rhs
  end

  # ── Helpers ─────────────────────────────────────────────────────

  @doc false
  def scalar_mod_n(binary) when is_binary(binary) do
    value = :binary.decode_unsigned(binary, :big)
    mod(value, @n)
  end

  # Modular arithmetic
  defp mod(a, m) do
    r = rem(a, m)
    if r < 0, do: r + m, else: r
  end

  # Modular inverse via extended Euclidean algorithm
  def mod_inv(a, m) do
    {g, x, _} = extended_gcd(mod(a, m), m)
    if g != 1, do: raise("no inverse"), else: mod(x, m)
  end

  defp extended_gcd(0, b), do: {b, 0, 1}

  defp extended_gcd(a, b) do
    {g, x, y} = extended_gcd(rem(b, a), a)
    {g, y - div(b, a) * x, x}
  end
end
