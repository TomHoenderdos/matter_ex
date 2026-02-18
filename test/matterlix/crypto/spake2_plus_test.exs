defmodule Matterlix.Crypto.SPAKE2PlusTest do
  use ExUnit.Case, async: true

  alias Matterlix.Crypto.{P256, SPAKE2Plus}

  @passcode 20_202_021
  @salt :crypto.strong_rand_bytes(32)
  @iterations 100

  # ── Verifier Computation ────────────────────────────────────────

  describe "compute_verifier" do
    test "returns w0, w1, and l" do
      v = SPAKE2Plus.compute_verifier(@passcode, @salt, @iterations)
      assert byte_size(v.w0) == 32
      assert byte_size(v.w1) == 32
      assert byte_size(v.l) == 65
      assert <<0x04, _::binary>> = v.l
    end

    test "l is on the curve" do
      v = SPAKE2Plus.compute_verifier(@passcode, @salt, @iterations)
      l_point = P256.decode_point(v.l)
      assert P256.on_curve?(l_point)
    end

    test "l == w1 * G" do
      v = SPAKE2Plus.compute_verifier(@passcode, @salt, @iterations)
      w1 = :binary.decode_unsigned(v.w1, :big)
      expected_l = P256.multiply(w1, P256.generator())
      assert P256.decode_point(v.l) == expected_l
    end

    test "same inputs produce same verifier" do
      salt = :crypto.strong_rand_bytes(32)
      v1 = SPAKE2Plus.compute_verifier(@passcode, salt, @iterations)
      v2 = SPAKE2Plus.compute_verifier(@passcode, salt, @iterations)
      assert v1 == v2
    end

    test "different passcodes produce different verifiers" do
      salt = :crypto.strong_rand_bytes(32)
      v1 = SPAKE2Plus.compute_verifier(1234, salt, @iterations)
      v2 = SPAKE2Plus.compute_verifier(5678, salt, @iterations)
      assert v1.w0 != v2.w0
    end
  end

  # ── Full Handshake ──────────────────────────────────────────────

  describe "full handshake" do
    test "prover and verifier derive same keys" do
      salt = :crypto.strong_rand_bytes(32)
      verifier = SPAKE2Plus.compute_verifier(@passcode, salt, @iterations)

      {pa, prover_ctx} = SPAKE2Plus.prover_start(verifier.w0)
      assert byte_size(pa) == 65

      {pb, verifier_keys} = SPAKE2Plus.verifier_respond(pa, %{w0: verifier.w0, l: verifier.l})
      assert byte_size(pb) == 65

      {:ok, prover_keys} = SPAKE2Plus.prover_finish(prover_ctx, pb, verifier.w1)

      assert prover_keys.ke == verifier_keys.ke
      assert byte_size(prover_keys.ke) == 16
    end

    test "confirmation MACs match" do
      salt = :crypto.strong_rand_bytes(32)
      verifier = SPAKE2Plus.compute_verifier(@passcode, salt, @iterations)

      {pa, prover_ctx} = SPAKE2Plus.prover_start(verifier.w0)
      {pb, verifier_keys} = SPAKE2Plus.verifier_respond(pa, %{w0: verifier.w0, l: verifier.l})
      {:ok, prover_keys} = SPAKE2Plus.prover_finish(prover_ctx, pb, verifier.w1)

      assert prover_keys.ca == verifier_keys.ca
      assert prover_keys.cb == verifier_keys.cb
    end

    test "key confirmation succeeds with correct MACs" do
      salt = :crypto.strong_rand_bytes(32)
      verifier = SPAKE2Plus.compute_verifier(@passcode, salt, @iterations)

      {pa, prover_ctx} = SPAKE2Plus.prover_start(verifier.w0)
      {pb, verifier_keys} = SPAKE2Plus.verifier_respond(pa, %{w0: verifier.w0, l: verifier.l})
      {:ok, prover_keys} = SPAKE2Plus.prover_finish(prover_ctx, pb, verifier.w1)

      assert :ok = SPAKE2Plus.verify_confirmation(prover_keys.cb, verifier_keys.cb)
      assert :ok = SPAKE2Plus.verify_confirmation(verifier_keys.ca, prover_keys.ca)
    end

    test "key confirmation fails with wrong MAC" do
      salt = :crypto.strong_rand_bytes(32)
      verifier = SPAKE2Plus.compute_verifier(@passcode, salt, @iterations)

      {pa, prover_ctx} = SPAKE2Plus.prover_start(verifier.w0)
      {pb, _verifier_keys} = SPAKE2Plus.verifier_respond(pa, %{w0: verifier.w0, l: verifier.l})
      {:ok, prover_keys} = SPAKE2Plus.prover_finish(prover_ctx, pb, verifier.w1)

      wrong_mac = :crypto.strong_rand_bytes(32)
      assert {:error, :confirmation_failed} = SPAKE2Plus.verify_confirmation(prover_keys.cb, wrong_mac)
    end

    test "wrong passcode produces different keys" do
      salt = :crypto.strong_rand_bytes(32)
      correct_verifier = SPAKE2Plus.compute_verifier(@passcode, salt, @iterations)
      wrong_verifier = SPAKE2Plus.compute_verifier(99999, salt, @iterations)

      {pa, prover_ctx} = SPAKE2Plus.prover_start(wrong_verifier.w0)

      {pb, verifier_keys} =
        SPAKE2Plus.verifier_respond(pa, %{w0: correct_verifier.w0, l: correct_verifier.l})

      {:ok, prover_keys} = SPAKE2Plus.prover_finish(prover_ctx, pb, wrong_verifier.w1)

      assert prover_keys.ke != verifier_keys.ke
    end
  end

  # ── Multiple Handshakes ─────────────────────────────────────────

  describe "multiple handshakes" do
    test "each handshake produces different session keys" do
      salt = :crypto.strong_rand_bytes(32)
      verifier = SPAKE2Plus.compute_verifier(@passcode, salt, @iterations)

      keys =
        for _ <- 1..3 do
          {pa, ctx} = SPAKE2Plus.prover_start(verifier.w0)
          {pb, _vk} = SPAKE2Plus.verifier_respond(pa, %{w0: verifier.w0, l: verifier.l})
          {:ok, pk} = SPAKE2Plus.prover_finish(ctx, pb, verifier.w1)
          pk.ke
        end

      assert length(Enum.uniq(keys)) == 3
    end
  end

  # ── Matter SDK RFC Test Vectors ─────────────────────────────────
  # From connectedhomeip/src/crypto/tests/SPAKE2P_RFC_test_vectors.h
  # These test vectors use fixed random scalars and verify all intermediate values.

  describe "Matter SDK RFC test vector 1 (client/server identities)" do
    # Shared across all RFC vectors
    @rfc_w0 Base.decode16!("E6887CF9BDFB7579C69BF47928A84514B5E355AC034863F7FFAF4390E67D798C")
    @rfc_w1 Base.decode16!("24B5AE4ABDA868EC9336FFC3B78EE31C5755BEF1759227EF5372CA139B94E512")
    @rfc_l Base.decode16!(
             "0495645CFB74DF6E58F9748BB83A86620BAB7C82E107F57D6870DA8CBCB2FF9F7063A14B6402C62F99AFCB9706A4D1A143273259FE76F1C605A3639745A92154B9"
           )

    @rfc_context "SPAKE2+-P256-SHA256-HKDF draft-01"

    # Vector 1 specific values
    @tv1_x_scalar :binary.decode_unsigned(
                     Base.decode16!(
                       "8B0F3F383905CF3A3BB955EF8FB62E24849DD349A05CA79AAFB18041D30CBDB6"
                     ),
                     :big
                   )
    @tv1_y_scalar :binary.decode_unsigned(
                     Base.decode16!(
                       "2E0895B0E763D6D5A9564433E64AC3CAC74FF897F6C3445247BA1BAB40082A91"
                     ),
                     :big
                   )

    @tv1_expected_x Base.decode16!(
                      "04AF09987A593D3BAC8694B123839422C3CC87E37D6B41C1D630F000DD64980E537AE704BCEDE04EA3BEC9B7475B32FA2CA3B684BE14D11645E38EA6609EB39E7E"
                    )
    @tv1_expected_y Base.decode16!(
                      "04417592620AEBF9FD203616BBB9F121B730C258B286F890C5F19FEA833A9C900CBE9057BC549A3E19975BE9927F0E7614F08D1F0A108EEDE5FD7EB5624584A4F4"
                    )
    @tv1_expected_ka Base.decode16!("F9CAB9ADCC0ED8E5A4DB11A8505914B2")
    @tv1_expected_ke Base.decode16!("801DB297654816EB4F02868129B9DC89")
    @tv1_expected_kca Base.decode16!("0D248D7D19234F1486B2EFBA5179C52D")
    @tv1_expected_kcb Base.decode16!("556291DF26D705A2CAEDD6474DD0079B")
    @tv1_expected_mac_kca Base.decode16!(
                            "D4376F2DA9C72226DD151B77C2919071155FC22A2068D90B5FAA6C78C11E77DD"
                          )
    @tv1_expected_mac_kcb Base.decode16!(
                            "0660A680663E8C5695956FB22DFF298B1D07A526CF3CC591ADFECD1F6EF6E02E"
                          )

    @rfc_opts [
      context: @rfc_context,
      prover_id: "client",
      verifier_id: "server"
    ]

    test "compute_l matches expected L" do
      computed_l = SPAKE2Plus.compute_l(@rfc_w1)
      assert computed_l == @rfc_l
    end

    test "prover generates correct X (pA)" do
      {pa, _ctx} = SPAKE2Plus.prover_start(@rfc_w0, random_scalar: @tv1_x_scalar)
      assert pa == @tv1_expected_x
    end

    test "verifier generates correct Y (pB)" do
      {pa, _ctx} = SPAKE2Plus.prover_start(@rfc_w0, random_scalar: @tv1_x_scalar)

      {pb, _keys} =
        SPAKE2Plus.verifier_respond(
          pa,
          %{w0: @rfc_w0, l: @rfc_l},
          [random_scalar: @tv1_y_scalar] ++ @rfc_opts
        )

      assert pb == @tv1_expected_y
    end

    test "full protocol produces correct Ke" do
      {pa, prover_ctx} = SPAKE2Plus.prover_start(@rfc_w0, random_scalar: @tv1_x_scalar)

      {pb, verifier_keys} =
        SPAKE2Plus.verifier_respond(
          pa,
          %{w0: @rfc_w0, l: @rfc_l},
          [random_scalar: @tv1_y_scalar] ++ @rfc_opts
        )

      {:ok, prover_keys} = SPAKE2Plus.prover_finish(prover_ctx, pb, @rfc_w1, @rfc_opts)

      assert prover_keys.ke == @tv1_expected_ke
      assert verifier_keys.ke == @tv1_expected_ke
    end

    test "full protocol produces correct Ka" do
      {pa, prover_ctx} = SPAKE2Plus.prover_start(@rfc_w0, random_scalar: @tv1_x_scalar)

      {pb, verifier_keys} =
        SPAKE2Plus.verifier_respond(
          pa,
          %{w0: @rfc_w0, l: @rfc_l},
          [random_scalar: @tv1_y_scalar] ++ @rfc_opts
        )

      {:ok, prover_keys} = SPAKE2Plus.prover_finish(prover_ctx, pb, @rfc_w1, @rfc_opts)

      assert prover_keys.ka == @tv1_expected_ka
      assert verifier_keys.ka == @tv1_expected_ka
    end

    test "full protocol produces correct KcA and KcB" do
      {pa, prover_ctx} = SPAKE2Plus.prover_start(@rfc_w0, random_scalar: @tv1_x_scalar)

      {pb, verifier_keys} =
        SPAKE2Plus.verifier_respond(
          pa,
          %{w0: @rfc_w0, l: @rfc_l},
          [random_scalar: @tv1_y_scalar] ++ @rfc_opts
        )

      {:ok, prover_keys} = SPAKE2Plus.prover_finish(prover_ctx, pb, @rfc_w1, @rfc_opts)

      assert prover_keys.kca == @tv1_expected_kca
      assert prover_keys.kcb == @tv1_expected_kcb
      assert verifier_keys.kca == @tv1_expected_kca
      assert verifier_keys.kcb == @tv1_expected_kcb
    end

    test "full protocol produces correct confirmation MACs" do
      {pa, prover_ctx} = SPAKE2Plus.prover_start(@rfc_w0, random_scalar: @tv1_x_scalar)

      {pb, verifier_keys} =
        SPAKE2Plus.verifier_respond(
          pa,
          %{w0: @rfc_w0, l: @rfc_l},
          [random_scalar: @tv1_y_scalar] ++ @rfc_opts
        )

      {:ok, prover_keys} = SPAKE2Plus.prover_finish(prover_ctx, pb, @rfc_w1, @rfc_opts)

      # MAC_KcA = HMAC(KcA, Y/pB) — prover confirms
      assert prover_keys.ca == @tv1_expected_mac_kca
      assert verifier_keys.ca == @tv1_expected_mac_kca

      # MAC_KcB = HMAC(KcB, X/pA) — verifier confirms
      assert prover_keys.cb == @tv1_expected_mac_kcb
      assert verifier_keys.cb == @tv1_expected_mac_kcb
    end
  end

  # ── RFC Test Vector 4 (empty identities) ────────────────────────

  describe "Matter SDK RFC test vector 4 (empty identities)" do
    @rfc_w0_v4 Base.decode16!("E6887CF9BDFB7579C69BF47928A84514B5E355AC034863F7FFAF4390E67D798C")
    @rfc_w1_v4 Base.decode16!("24B5AE4ABDA868EC9336FFC3B78EE31C5755BEF1759227EF5372CA139B94E512")
    @rfc_l_v4 Base.decode16!(
                "0495645CFB74DF6E58F9748BB83A86620BAB7C82E107F57D6870DA8CBCB2FF9F7063A14B6402C62F99AFCB9706A4D1A143273259FE76F1C605A3639745A92154B9"
              )
    @rfc_context_v4 "SPAKE2+-P256-SHA256-HKDF draft-01"

    @tv4_x_scalar :binary.decode_unsigned(
                     Base.decode16!(
                       "5B478619804F4938D361FBBA3A20648725222F0A54CC4C876139EFE7D9A21786"
                     ),
                     :big
                   )
    @tv4_y_scalar :binary.decode_unsigned(
                     Base.decode16!(
                       "766770DAD8C8EECBA936823C0AED044B8C3C4F7655E8BEEC44A15DCBCAF78E5E"
                     ),
                     :big
                   )

    @tv4_expected_x Base.decode16!(
                      "04A6DB23D001723FB01FCFC9D08746C3C2A0A3FEFF8635D29CAD2853E7358623425CF39712E928054561BA71E2DC11F300F1760E71EB177021A8F85E78689071CD"
                    )
    @tv4_expected_y Base.decode16!(
                      "04390D29BF185C3ABF99F150AE7C13388C82B6BE0C07B1B8D90D26853E84374BBDC82BECDB978CA3792F472424106A2578012752C11938FCF60A41DF75FF7CF947"
                    )
    @tv4_expected_ke Base.decode16!("EA3276D68334576097E04B19EE5A3A8B")

    @tv4_expected_mac_kca Base.decode16!(
                            "71D9412779B6C45A2C615C9DF3F1FD93DC0AAF63104DA8ECE4AA1B5A3A415FEA"
                          )
    @tv4_opts [
      context: @rfc_context_v4,
      prover_id: <<>>,
      verifier_id: <<>>
    ]

    test "pA and pB match expected values" do
      {pa, _ctx} = SPAKE2Plus.prover_start(@rfc_w0_v4, random_scalar: @tv4_x_scalar)
      assert pa == @tv4_expected_x

      {pb, _keys} =
        SPAKE2Plus.verifier_respond(
          pa,
          %{w0: @rfc_w0_v4, l: @rfc_l_v4},
          [random_scalar: @tv4_y_scalar] ++ @tv4_opts
        )

      assert pb == @tv4_expected_y
    end

    test "Ke matches expected value" do
      {pa, prover_ctx} = SPAKE2Plus.prover_start(@rfc_w0_v4, random_scalar: @tv4_x_scalar)

      {pb, verifier_keys} =
        SPAKE2Plus.verifier_respond(
          pa,
          %{w0: @rfc_w0_v4, l: @rfc_l_v4},
          [random_scalar: @tv4_y_scalar] ++ @tv4_opts
        )

      {:ok, prover_keys} = SPAKE2Plus.prover_finish(prover_ctx, pb, @rfc_w1_v4, @tv4_opts)

      assert prover_keys.ke == @tv4_expected_ke
      assert verifier_keys.ke == @tv4_expected_ke
    end

    test "confirmation MACs match expected values" do
      {pa, prover_ctx} = SPAKE2Plus.prover_start(@rfc_w0_v4, random_scalar: @tv4_x_scalar)

      {pb, _verifier_keys} =
        SPAKE2Plus.verifier_respond(
          pa,
          %{w0: @rfc_w0_v4, l: @rfc_l_v4},
          [random_scalar: @tv4_y_scalar] ++ @tv4_opts
        )

      {:ok, prover_keys} = SPAKE2Plus.prover_finish(prover_ctx, pb, @rfc_w1_v4, @tv4_opts)

      assert prover_keys.ca == @tv4_expected_mac_kca
    end
  end
end
