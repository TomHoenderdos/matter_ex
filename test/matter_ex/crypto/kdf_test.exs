defmodule MatterEx.Crypto.KDFTest do
  use ExUnit.Case, async: true

  alias MatterEx.Crypto.KDF

  # ── HKDF (RFC 5869 Test Vectors) ──────────────────────────────────

  describe "HKDF-SHA256" do
    # RFC 5869 Test Case 1
    test "test case 1" do
      ikm = Base.decode16!("0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B")
      salt = Base.decode16!("000102030405060708090A0B0C")
      info = Base.decode16!("F0F1F2F3F4F5F6F7F8F9")
      l = 42

      expected_prk =
        Base.decode16!("077709362C2E32DF0DDC3F0DC47BBA6390B6C73BB50F9C3122EC844AD7C2B3E5")

      expected_okm =
        Base.decode16!(
          "3CB25F25FAACD57A90434F64D0362F2A2D2D0A90CF1A5A4C5DB02D56ECC4C5BF34007208D5B887185865"
        )

      assert expected_prk == KDF.hkdf_extract(ikm, salt)
      assert expected_okm == KDF.hkdf(salt, ikm, info, l)
    end

    # RFC 5869 Test Case 2
    test "test case 2 — longer inputs" do
      ikm =
        Base.decode16!(
          "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F303132333435363738393A3B3C3D3E3F404142434445464748494A4B4C4D4E4F"
        )

      salt =
        Base.decode16!(
          "606162636465666768696A6B6C6D6E6F707172737475767778797A7B7C7D7E7F808182838485868788898A8B8C8D8E8F909192939495969798999A9B9C9D9E9FA0A1A2A3A4A5A6A7A8A9AAABACADAEAF"
        )

      info =
        Base.decode16!(
          "B0B1B2B3B4B5B6B7B8B9BABBBCBDBEBFC0C1C2C3C4C5C6C7C8C9CACBCCCDCECFD0D1D2D3D4D5D6D7D8D9DADBDCDDDEDFE0E1E2E3E4E5E6E7E8E9EAEBECEDEEEFF0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF"
        )

      l = 82

      expected_okm =
        Base.decode16!(
          "B11E398DC80327A1C8E7F78C596A49344F012EDA2D4EFAD8A050CC4C19AFA97C59045A99CAC7827271CB41C65E590E09DA3275600C2F09B8367793A9ACA3DB71CC30C58179EC3E87C14C01D5C1F3434F1D87"
        )

      assert expected_okm == KDF.hkdf(salt, ikm, info, l)
    end

    # RFC 5869 Test Case 3 — empty salt and info
    test "test case 3 — empty salt and info" do
      ikm = Base.decode16!("0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B")
      salt = <<>>
      info = <<>>
      l = 42

      expected_okm =
        Base.decode16!(
          "8DA4E775A563C18F715F802A063C5A31B8A11F5C5EE1879EC3454E5F3C738D2D9D201395FAA4B61A96C8"
        )

      assert expected_okm == KDF.hkdf(salt, ikm, info, l)
    end

    test "extract then expand gives same result as hkdf" do
      ikm = :crypto.strong_rand_bytes(32)
      salt = :crypto.strong_rand_bytes(16)
      info = "test info"

      prk = KDF.hkdf_extract(ikm, salt)
      okm1 = KDF.hkdf_expand(prk, info, 48)
      okm2 = KDF.hkdf(salt, ikm, info, 48)
      assert okm1 == okm2
    end

    test "different info produces different output" do
      ikm = :crypto.strong_rand_bytes(32)
      salt = :crypto.strong_rand_bytes(16)

      okm1 = KDF.hkdf(salt, ikm, "info1", 32)
      okm2 = KDF.hkdf(salt, ikm, "info2", 32)
      assert okm1 != okm2
    end
  end

  # ── PBKDF2-SHA256 ─────────────────────────────────────────────────

  describe "PBKDF2-HMAC-SHA256" do
    # Test vector from RFC 7914 section 11 (PBKDF2-HMAC-SHA256)
    test "password 'passwd', salt 'salt', iterations=1, dkLen=64" do
      result = KDF.pbkdf2_sha256("passwd", "salt", 1, 64)

      expected =
        Base.decode16!(
          "55AC046E56E3089FEC1691C22544B605F94185216DDE0465E68B9D57C20DACBC49CA9CCCF179B645991664B39D77EF317C71B845B1E30BD509112041D3A19783"
        )

      assert result == expected
    end

    test "single iteration" do
      result = KDF.pbkdf2_sha256("password", "salt", 1, 32)
      assert byte_size(result) == 32
    end

    test "multiple iterations" do
      result = KDF.pbkdf2_sha256("password", "salt", 100, 32)
      assert byte_size(result) == 32
      # Different from single iteration
      assert result != KDF.pbkdf2_sha256("password", "salt", 1, 32)
    end

    test "different passwords produce different output" do
      r1 = KDF.pbkdf2_sha256("password1", "salt", 10, 32)
      r2 = KDF.pbkdf2_sha256("password2", "salt", 10, 32)
      assert r1 != r2
    end

    test "different salts produce different output" do
      r1 = KDF.pbkdf2_sha256("password", "salt1", 10, 32)
      r2 = KDF.pbkdf2_sha256("password", "salt2", 10, 32)
      assert r1 != r2
    end

    test "output length respected" do
      for len <- [16, 32, 48, 64, 80] do
        result = KDF.pbkdf2_sha256("password", "salt", 10, len)
        assert byte_size(result) == len
      end
    end

    test "matter-style: 80 bytes for SPAKE2+ w0/w1 derivation" do
      # Matter uses PBKDF2 to derive 80 bytes (40 for w0s, 40 for w1s)
      result = KDF.pbkdf2_sha256("20202021", "salt123", 1000, 80)
      assert byte_size(result) == 80
    end
  end
end
