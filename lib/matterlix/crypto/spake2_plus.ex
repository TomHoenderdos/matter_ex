defmodule Matterlix.Crypto.SPAKE2Plus do
  @moduledoc """
  SPAKE2+ implementation for Matter PASE commissioning.

  Uses P-256 curve with Matter-specific M and N points per Matter spec
  section 3.10 and RFC 9383.
  """

  alias Matterlix.Crypto.{KDF, P256}

  # Matter-specific M and N points (from Matter spec / RFC 9383 for P-256)
  @m_point {
    0x886E2F97ACE46E55BA9DD7242579F2993B64E16EF3DCAB95AFD497333D8FA12F,
    0x5FF355163E43CE224E0B0E65FF02AC8E5C7BE09419C785E0CA547D55A12E2D20
  }

  @n_point {
    0xD8BBD6C639C62937B04D997F38C3770719C629D7014D49A24B4F98BAA1292B49,
    0x07D60AA6BFADE45008A636337F5168C64D9BD36034808CD564490B1E656EDBE7
  }

  @default_context "CHIP PASE V1 Commissioning"

  @doc """
  Compute SPAKE2+ verifier from passcode (done once, stored on device).

  Returns `%{w0: binary, w1: binary, l: binary}` where:
  - w0, w1 are 32-byte scalars (mod n)
  - l is the SEC1 encoded point w1 * G (65 bytes)
  """
  @spec compute_verifier(non_neg_integer(), binary(), pos_integer()) :: map()
  def compute_verifier(passcode, salt, iterations) do
    # PBKDF2 to derive 80 bytes: w0s (40 bytes) || w1s (40 bytes)
    ws = KDF.pbkdf2_sha256(Integer.to_string(passcode), salt, iterations, 80)
    w0s = binary_part(ws, 0, 40)
    w1s = binary_part(ws, 40, 40)

    w0 = P256.scalar_mod_n(w0s)
    w1 = P256.scalar_mod_n(w1s)

    # L = w1 * G
    l_point = P256.multiply(w1, P256.generator())

    %{
      w0: <<w0::unsigned-big-256>>,
      w1: <<w1::unsigned-big-256>>,
      l: P256.encode_point(l_point)
    }
  end

  @doc """
  Compute L = w1 * G from a 32-byte w1 scalar. Returns 65-byte SEC1 point.
  """
  @spec compute_l(binary()) :: binary()
  def compute_l(w1_binary) when byte_size(w1_binary) == 32 do
    w1 = :binary.decode_unsigned(w1_binary, :big)
    P256.encode_point(P256.multiply(w1, P256.generator()))
  end

  @doc """
  Prover (commissioner) start: generate pA = x*G + w0*M.

  Takes a 32-byte w0 scalar. Returns `{pA_encoded, prover_context}` where
  prover_context is an opaque map passed to `prover_finish/4`.

  Options:
  - `:random_scalar` — inject a fixed scalar for deterministic testing
  """
  @spec prover_start(binary(), keyword()) :: {binary(), map()}
  def prover_start(w0_binary, opts \\ []) when byte_size(w0_binary) == 32 do
    w0 = :binary.decode_unsigned(w0_binary, :big)

    x = opts[:random_scalar] || random_scalar()
    x_pub = P256.multiply(x, P256.generator())

    # pA = x*G + w0*M
    w0_m = P256.multiply(w0, @m_point)
    pa = P256.add(x_pub, w0_m)

    pa_encoded = P256.encode_point(pa)
    {pa_encoded, %{x: x, w0: w0, pa: pa_encoded}}
  end

  @doc """
  Verifier (device) respond: given pA from prover, compute pB and derive session keys.

  Takes the prover's encoded public share and a verifier map `%{w0: binary, l: binary}`.
  Returns `{pB_encoded, keys}` where keys contains `:ke`, `:ka`, `:kca`, `:kcb`, `:ca`, `:cb`.

  Options:
  - `:random_scalar` — inject a fixed scalar for deterministic testing
  - `:context` — override the transcript context string (default: `"CHIP PASE V1 Commissioning"`)
  - `:prover_id` — prover identity for transcript (default: empty)
  - `:verifier_id` — verifier identity for transcript (default: empty)
  """
  @spec verifier_respond(binary(), map(), keyword()) :: {binary(), map()}
  def verifier_respond(pa_encoded, %{w0: w0_binary, l: l_encoded}, opts \\ []) do
    w0 = :binary.decode_unsigned(w0_binary, :big)
    pa = P256.decode_point(pa_encoded)
    l_point = P256.decode_point(l_encoded)

    y = opts[:random_scalar] || random_scalar()
    y_pub = P256.multiply(y, P256.generator())

    # pB = y*G + w0*N
    w0_n = P256.multiply(w0, @n_point)
    pb = P256.add(y_pub, w0_n)

    # Z = y * (pA - w0*M)
    w0_m = P256.multiply(w0, @m_point)
    z = P256.multiply(y, P256.add(pa, P256.negate(w0_m)))

    # V = y * L
    v = P256.multiply(y, l_point)

    pb_encoded = P256.encode_point(pb)
    keys = derive_keys(pa_encoded, pb_encoded, z, v, w0_binary, opts)

    {pb_encoded, keys}
  end

  @doc """
  Prover (commissioner) finish: given pB from verifier, derive session keys.

  Takes the prover_context from `prover_start/2`, the verifier's encoded public
  share, and the 32-byte w1 scalar. Returns `{:ok, keys}` with the same key map
  as `verifier_respond/3`.

  Options:
  - `:context` — override the transcript context string (default: `"CHIP PASE V1 Commissioning"`)
  - `:prover_id` — prover identity for transcript (default: empty)
  - `:verifier_id` — verifier identity for transcript (default: empty)
  """
  @spec prover_finish(map(), binary(), binary(), keyword()) :: {:ok, map()}
  def prover_finish(%{x: x, w0: w0, pa: pa_encoded}, pb_encoded, w1_binary, opts \\ [])
      when byte_size(w1_binary) == 32 do
    w1 = :binary.decode_unsigned(w1_binary, :big)
    pb = P256.decode_point(pb_encoded)

    # Z = x * (pB - w0*N)
    w0_n = P256.multiply(w0, @n_point)
    pb_minus_w0n = P256.add(pb, P256.negate(w0_n))
    z = P256.multiply(x, pb_minus_w0n)

    # V = w1 * (pB - w0*N)
    v = P256.multiply(w1, pb_minus_w0n)

    w0_binary = <<w0::unsigned-big-256>>
    keys = derive_keys(pa_encoded, pb_encoded, z, v, w0_binary, opts)
    {:ok, keys}
  end

  @doc """
  Constant-time comparison of expected vs received confirmation MAC (cA or cB).
  """
  @spec verify_confirmation(binary(), binary()) :: :ok | {:error, :confirmation_failed}
  def verify_confirmation(expected, received) do
    if constant_time_compare(expected, received) do
      :ok
    else
      {:error, :confirmation_failed}
    end
  end

  # ── Private ─────────────────────────────────────────────────────

  # Derive session keys from SPAKE2+ transcript
  # TT = Hash(context || idProver || idVerifier || M || N || pA || pB || Z || V || w0)
  defp derive_keys(pa_encoded, pb_encoded, z_point, v_point, w0_binary, opts) do
    z_encoded = P256.encode_point(z_point)
    v_encoded = P256.encode_point(v_point)

    context = Keyword.get(opts, :context, @default_context)
    prover_id = Keyword.get(opts, :prover_id, <<>>)
    verifier_id = Keyword.get(opts, :verifier_id, <<>>)

    tt =
      hash_transcript([
        length_prefixed(context),
        length_prefixed(prover_id),
        length_prefixed(verifier_id),
        length_prefixed(P256.encode_point(@m_point)),
        length_prefixed(P256.encode_point(@n_point)),
        length_prefixed(pa_encoded),
        length_prefixed(pb_encoded),
        length_prefixed(z_encoded),
        length_prefixed(v_encoded),
        length_prefixed(w0_binary)
      ])

    # Ka || Ke = Hash(TT) — SHA-256 of transcript, split into two 16-byte halves
    # (tt is already the hash from hash_transcript/1)
    ka = binary_part(tt, 0, 16)
    ke = binary_part(tt, 16, 16)

    # KcA || KcB = HKDF(salt=<<>>, ikm=Ka, "ConfirmationKeys", 32)
    kca_kcb = KDF.hkdf(<<>>, ka, "ConfirmationKeys", 32)
    kca_key = binary_part(kca_kcb, 0, 16)
    kcb_key = binary_part(kca_kcb, 16, 16)

    # Confirmation MACs: cA = HMAC(KcA, pB), cB = HMAC(KcB, pA)
    ca = :crypto.mac(:hmac, :sha256, kca_key, pb_encoded)
    cb = :crypto.mac(:hmac, :sha256, kcb_key, pa_encoded)

    %{ke: ke, ka: ka, kca: kca_key, kcb: kcb_key, ca: ca, cb: cb}
  end

  defp hash_transcript(parts) do
    data = IO.iodata_to_binary(parts)
    :crypto.hash(:sha256, data)
  end

  defp length_prefixed(data) do
    len = byte_size(data)
    <<len::unsigned-little-64, data::binary>>
  end

  defp random_scalar do
    bytes = :crypto.strong_rand_bytes(32)
    scalar = :binary.decode_unsigned(bytes, :big)
    n = P256.n()
    rem(scalar, n - 1) + 1
  end

  defp constant_time_compare(a, b) do
    # Hash both to normalize length, so we never early-return on size mismatch.
    :crypto.hash_equals(:crypto.hash(:sha256, a), :crypto.hash(:sha256, b))
  end
end
