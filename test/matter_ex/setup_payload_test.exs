defmodule MatterEx.SetupPayloadTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias MatterEx.SetupPayload

  describe "qr_code_payload/1" do
    test "all-clusters-app test vector (vendor=0xFFF1, product=0x8000)" do
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

    test "lighting-app test vector (vendor=0xFFF1, product=0x8001)" do
      payload =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8001,
          discriminator: 3840,
          passcode: 20202021,
          flow: 0,
          discovery: 2
        )

      assert payload == "MT:-24J042C00KA0648G00"
    end

    test "payload is exactly 22 characters (MT: prefix + 19 base-38 chars)" do
      payload =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFF1,
          product_id: 0x8001,
          discriminator: 3840,
          passcode: 20202021
        )

      assert String.length(payload) == 22
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

    test "boundary values: minimum" do
      payload =
        SetupPayload.qr_code_payload(
          vendor_id: 0,
          product_id: 0,
          discriminator: 0,
          passcode: 1,
          flow: 0,
          discovery: 0
        )

      assert String.length(payload) == 22
    end

    test "boundary values: maximum" do
      payload =
        SetupPayload.qr_code_payload(
          vendor_id: 0xFFFF,
          product_id: 0xFFFF,
          discriminator: 0xFFF,
          passcode: 99999998,
          flow: 3,
          discovery: 0xFF
        )

      assert String.length(payload) == 22
    end

    test "rejects invalid passcode" do
      for invalid <- [0, 11111111, 22222222, 33333333, 44444444, 55555555,
                      66666666, 77777777, 88888888, 99999999, 12345678, 87654321] do
        assert_raise ArgumentError, fn ->
          SetupPayload.qr_code_payload(
            vendor_id: 0, product_id: 0, discriminator: 0, passcode: invalid
          )
        end
      end
    end

    test "rejects out-of-range values" do
      assert_raise ArgumentError, ~r/discriminator/, fn ->
        SetupPayload.qr_code_payload(
          vendor_id: 0, product_id: 0, discriminator: 5000, passcode: 20202021
        )
      end

      assert_raise ArgumentError, ~r/vendor_id/, fn ->
        SetupPayload.qr_code_payload(
          vendor_id: 0x1FFFF, product_id: 0, discriminator: 0, passcode: 20202021
        )
      end

      assert_raise ArgumentError, ~r/passcode/, fn ->
        SetupPayload.qr_code_payload(
          vendor_id: 0, product_id: 0, discriminator: 0, passcode: -1
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
    test "standard test vector (disc=3840, passcode=20202021)" do
      assert SetupPayload.manual_pairing_code(discriminator: 3840, passcode: 20202021) ==
               "34970112332"
    end

    test "second test vector (disc=0, passcode=20202021)" do
      # discriminator 0 → short_disc=0 → digit1=0, chunk2=passcode_low, chunk3=passcode_high
      code = SetupPayload.manual_pairing_code(discriminator: 0, passcode: 20202021)
      assert String.length(code) == 11
      assert String.at(code, 0) == "0"
      # Verify round-trip: extract chunks and reconstruct passcode
      <<d1::binary-1, c2::binary-5, c3::binary-4, _check::binary-1>> = code
      {chunk2, ""} = Integer.parse(c2)
      {chunk3, ""} = Integer.parse(c3)
      short_disc = (chunk2 >>> 14) &&& 0xF
      passcode_low = chunk2 &&& 0x3FFF
      passcode_high = chunk3 &&& 0x1FFF
      assert short_disc == 0
      assert Bitwise.bor(Bitwise.bsl(passcode_high, 14), passcode_low) == 20202021
      {digit1, ""} = Integer.parse(d1)
      assert digit1 == 0
    end

    test "produces 11-digit string" do
      code = SetupPayload.manual_pairing_code(discriminator: 3840, passcode: 20202021)
      assert String.length(code) == 11
      assert String.match?(code, ~r/^\d{11}$/)
    end

    test "different passcodes produce different codes" do
      code1 = SetupPayload.manual_pairing_code(discriminator: 3840, passcode: 20202021)
      code2 = SetupPayload.manual_pairing_code(discriminator: 3840, passcode: 12345679)
      refute code1 == code2
    end

    test "different discriminators produce different codes" do
      code1 = SetupPayload.manual_pairing_code(discriminator: 3840, passcode: 20202021)
      code2 = SetupPayload.manual_pairing_code(discriminator: 0, passcode: 20202021)
      refute code1 == code2
    end

    test "first digit encodes vid_pid_present and discriminator MSBs" do
      # digit1 = (vid_pid_present << 2) | (short_disc >> 2)
      # disc 3840 → short_disc = 15 → top 2 bits = 3

      # Standard flow: 0 << 2 | 3 = 3
      code = SetupPayload.manual_pairing_code(discriminator: 3840, passcode: 20202021, flow: 0)
      assert String.at(code, 0) == "3"

      # Custom flow: 1 << 2 | 3 = 7
      code = SetupPayload.manual_pairing_code(discriminator: 3840, passcode: 20202021, flow: 2)
      assert String.at(code, 0) == "7"

      # disc 0 → short_disc = 0 → standard flow digit = 0
      code = SetupPayload.manual_pairing_code(discriminator: 0, passcode: 20202021, flow: 0)
      assert String.at(code, 0) == "0"
    end

    test "boundary: max discriminator" do
      code = SetupPayload.manual_pairing_code(discriminator: 4095, passcode: 20202021)
      assert String.length(code) == 11
      assert String.match?(code, ~r/^\d{11}$/)
    end

    test "rejects invalid passcode" do
      assert_raise ArgumentError, fn ->
        SetupPayload.manual_pairing_code(discriminator: 0, passcode: 0)
      end

      assert_raise ArgumentError, fn ->
        SetupPayload.manual_pairing_code(discriminator: 0, passcode: 11111111)
      end
    end

    test "rejects out-of-range discriminator" do
      assert_raise ArgumentError, fn ->
        SetupPayload.manual_pairing_code(discriminator: 4096, passcode: 20202021)
      end
    end
  end
end
