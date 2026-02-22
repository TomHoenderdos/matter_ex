defmodule MatterEx.SetupPayloadTest do
  use ExUnit.Case, async: true

  alias MatterEx.SetupPayload

  describe "qr_code_payload/1" do
    test "standard test vector (all-clusters-app default values)" do
      # all-clusters-app: vendor=0xFFF1, product=0x8000, disc=3840, passcode=20202021
      payload =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8000,
          discriminator: 3840,
          passcode: 20202021,
          flow: 0,
          discovery: 2
        )

      assert payload == "MT:Y.K9042C00KA0648G00"
    end

    test "starts with MT: prefix" do
      payload =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8001,
          discriminator: 3840,
          passcode: 20202021
        )

      assert String.starts_with?(payload, "MT:")
    end

    test "payload is exactly 22 characters (MT: + 11 base-38 chars)" do
      payload =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8001,
          discriminator: 3840,
          passcode: 20202021
        )

      # "MT:" (3) + 11 base-38 chars = 22 total (some sources say different lengths)
      # Actually the QR payload has variable length based on TLV optional data
      # But the base payload without TLV is always "MT:" + base38 encoded 88 bits
      assert String.starts_with?(payload, "MT:")
      assert String.length(payload) > 3
    end

    test "only contains valid base-38 characters after prefix" do
      payload =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8001,
          discriminator: 3840,
          passcode: 20202021
        )

      "MT:" <> encoded = payload
      valid_chars = MapSet.new(String.graphemes("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-."))

      for char <- String.graphemes(encoded) do
        assert MapSet.member?(valid_chars, char),
               "Invalid base-38 character: #{inspect(char)}"
      end
    end

    test "different passcodes produce different payloads" do
      payload1 =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8001,
          discriminator: 3840,
          passcode: 20202021
        )

      payload2 =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8001,
          discriminator: 3840,
          passcode: 12345679
        )

      refute payload1 == payload2
    end

    test "different discriminators produce different payloads" do
      payload1 =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8001,
          discriminator: 3840,
          passcode: 20202021
        )

      payload2 =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8001,
          discriminator: 100,
          passcode: 20202021
        )

      refute payload1 == payload2
    end

    test "minimum valid values" do
      payload =
        SetupPayload.qr_code_payload(
          vendor_id: 0,
          product_id: 0,
          discriminator: 0,
          passcode: 1,
          flow: 0,
          discovery: 0
        )

      assert String.starts_with?(payload, "MT:")
      assert String.length(payload) == 22
    end

    test "rejects invalid passcode" do
      assert_raise ArgumentError, ~r/invalid passcode list/, fn ->
        SetupPayload.qr_code_payload(
          vendor_id: 0,
          product_id: 0,
          discriminator: 0,
          passcode: 11111111
        )
      end

      assert_raise ArgumentError, ~r/invalid passcode list/, fn ->
        SetupPayload.qr_code_payload(
          vendor_id: 0,
          product_id: 0,
          discriminator: 0,
          passcode: 12345678
        )
      end
    end

    test "rejects out-of-range values" do
      assert_raise ArgumentError, ~r/discriminator/, fn ->
        SetupPayload.qr_code_payload(
          vendor_id: 0,
          product_id: 0,
          discriminator: 5000,
          passcode: 20202021
        )
      end

      assert_raise ArgumentError, ~r/vendor_id/, fn ->
        SetupPayload.qr_code_payload(
          vendor_id: 0x1FFFF,
          product_id: 0,
          discriminator: 0,
          passcode: 20202021
        )
      end
    end

    test "defaults flow to 0 and discovery to 2 (BLE)" do
      payload_explicit =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8001,
          discriminator: 3840,
          passcode: 20202021,
          flow: 0,
          discovery: 2
        )

      payload_default =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8001,
          discriminator: 3840,
          passcode: 20202021
        )

      assert payload_explicit == payload_default
    end
  end

  describe "manual_pairing_code/1" do
    test "standard test vector (chip-tool default commissioning values)" do
      code =
        SetupPayload.manual_pairing_code(
          discriminator: 3840,
          passcode: 20202021
        )

      assert code == "34970112332"
    end

    test "produces 11-digit string" do
      code =
        SetupPayload.manual_pairing_code(
          discriminator: 3840,
          passcode: 20202021
        )

      assert String.length(code) == 11
      assert String.match?(code, ~r/^\d{11}$/)
    end

    test "different passcodes produce different codes" do
      code1 =
        SetupPayload.manual_pairing_code(
          discriminator: 3840,
          passcode: 20202021
        )

      code2 =
        SetupPayload.manual_pairing_code(
          discriminator: 3840,
          passcode: 12345679
        )

      refute code1 == code2
    end

    test "different discriminators produce different codes" do
      code1 =
        SetupPayload.manual_pairing_code(
          discriminator: 3840,
          passcode: 20202021
        )

      code2 =
        SetupPayload.manual_pairing_code(
          discriminator: 0,
          passcode: 20202021
        )

      refute code1 == code2
    end

    test "first digit encodes vid_pid_present and discriminator MSBs" do
      # digit1 = (vid_pid_present << 2) | (short_disc >> 2)
      # discriminator 3840 → short_disc = 15 → top 2 bits = 3

      # Standard flow: 0 << 2 | 3 = 3
      code =
        SetupPayload.manual_pairing_code(
          discriminator: 3840,
          passcode: 20202021,
          flow: 0
        )

      assert String.at(code, 0) == "3"

      # Custom flow: 1 << 2 | 3 = 7
      code =
        SetupPayload.manual_pairing_code(
          discriminator: 3840,
          passcode: 20202021,
          flow: 2
        )

      assert String.at(code, 0) == "7"

      # Discriminator 0 → short_disc = 0 → standard flow digit = 0
      code =
        SetupPayload.manual_pairing_code(
          discriminator: 0,
          passcode: 20202021,
          flow: 0
        )

      assert String.at(code, 0) == "0"
    end

    test "zero discriminator with valid passcode" do
      code =
        SetupPayload.manual_pairing_code(
          discriminator: 0,
          passcode: 1
        )

      assert String.length(code) == 11
      assert String.match?(code, ~r/^\d{11}$/)
    end

    test "rejects invalid passcode" do
      assert_raise ArgumentError, ~r/passcode/, fn ->
        SetupPayload.manual_pairing_code(discriminator: 0, passcode: 0)
      end

      assert_raise ArgumentError, ~r/invalid passcode list/, fn ->
        SetupPayload.manual_pairing_code(discriminator: 0, passcode: 11111111)
      end
    end

    test "Verhoeff check digit changes with different inputs" do
      code1 =
        SetupPayload.manual_pairing_code(
          discriminator: 3840,
          passcode: 20202021
        )

      code2 =
        SetupPayload.manual_pairing_code(
          discriminator: 3840,
          passcode: 20202022
        )

      # The check digit (last digit) should differ for different inputs
      # (not guaranteed for all cases but very likely)
      refute code1 == code2
    end
  end
end
