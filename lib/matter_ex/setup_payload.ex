defmodule MatterEx.SetupPayload do
  @moduledoc """
  Encodes Matter setup payloads for QR codes and manual pairing codes.

  ## QR Code Payload (Matter spec 5.1.3)

  Packs device info into 88 bits, base-38 encodes with prefix `"MT:"`.

      MatterEx.SetupPayload.qr_code_payload(
        vendor_id: 0xFFF1,
        product_id: 0x8000,
        discriminator: 3840,
        passcode: 20202021
      )
      #=> "MT:Y.K9042C00KA0648G00"

  ## Manual Pairing Code (Matter spec 5.1.4)

  11-digit decimal code with Verhoeff check digit.

      MatterEx.SetupPayload.manual_pairing_code(
        discriminator: 3840,
        passcode: 20202021
      )
      #=> "34970112332"
  """

  import Bitwise

  # Base-38 alphabet as tuple for O(1) lookup (Matter spec Table 39)
  @base38_alphabet {?0, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9,
                    ?A, ?B, ?C, ?D, ?E, ?F, ?G, ?H, ?I, ?J,
                    ?K, ?L, ?M, ?N, ?O, ?P, ?Q, ?R, ?S, ?T,
                    ?U, ?V, ?W, ?X, ?Y, ?Z, ?-, ?.}

  # ── QR Code Payload ──────────────────────────────────────────────────

  @doc """
  Generates a Matter QR code payload string.

  ## Options

    * `:vendor_id` — 16-bit vendor ID (required)
    * `:product_id` — 16-bit product ID (required)
    * `:discriminator` — 12-bit discriminator 0..4095 (required)
    * `:passcode` — 27-bit setup passcode (required)
    * `:flow` — commissioning flow, 0..3 (default 0 = standard)
    * `:discovery` — discovery capabilities bitmask (default 2 = BLE)
    * `:version` — payload version, 0..7 (default 0)
  """
  def qr_code_payload(opts) do
    version = Keyword.get(opts, :version, 0) &&& 0x7
    vendor_id = Keyword.fetch!(opts, :vendor_id) &&& 0xFFFF
    product_id = Keyword.fetch!(opts, :product_id) &&& 0xFFFF
    flow = Keyword.get(opts, :flow, 0) &&& 0x3
    discovery = Keyword.get(opts, :discovery, 2) &&& 0xFF
    discriminator = Keyword.fetch!(opts, :discriminator) &&& 0xFFF
    passcode = Keyword.fetch!(opts, :passcode) &&& 0x7FFFFFF

    # Pack 88 bits using LSB-first bit ordering:
    #   bits  0-2:  version (3)
    #   bits  3-18: vendor_id (16)
    #   bits 19-34: product_id (16)
    #   bits 35-36: flow (2)
    #   bits 37-44: discovery (8)
    #   bits 45-56: discriminator (12)
    #   bits 57-83: passcode (27)
    #   bits 84-87: padding (4)
    packed =
      version
      ||| (vendor_id <<< 3)
      ||| (product_id <<< 19)
      ||| (flow <<< 35)
      ||| (discovery <<< 37)
      ||| (discriminator <<< 45)
      ||| (passcode <<< 57)

    # Extract 11 bytes in little-endian order
    bytes = for i <- 0..10, do: (packed >>> (i * 8)) &&& 0xFF

    # Base-38 encode in chunks: 3, 3, 3, 2 bytes
    "MT:" <> base38_encode_chunked(bytes)
  end

  # ── Manual Pairing Code ──────────────────────────────────────────────

  @doc """
  Generates an 11-digit manual pairing code.

  ## Options

    * `:discriminator` — 12-bit discriminator (required, only top 4 bits used)
    * `:passcode` — 27-bit setup passcode (required)
    * `:flow` — commissioning flow, 0 = standard (default 0).
      When non-zero, the vid_pid_present bit is set.
  """
  def manual_pairing_code(opts) do
    discriminator = Keyword.fetch!(opts, :discriminator)
    passcode = Keyword.fetch!(opts, :passcode)
    flow = Keyword.get(opts, :flow, 0)

    # Short discriminator: top 4 bits of the 12-bit discriminator
    short_disc = (discriminator >>> 8) &&& 0xF
    vid_pid_present = if flow != 0, do: 1, else: 0

    # Digit 1 (1 digit): vid_pid_present(1 bit) | discriminator bits [11:10] (2 bits)
    digit1 = (vid_pid_present <<< 2) ||| ((short_disc >>> 2) &&& 0x3)

    # Chunk 2 (5 digits): discriminator bits [9:8] (2 bits) | passcode bits [13:0] (14 bits)
    chunk2 = ((short_disc &&& 0x3) <<< 14) ||| (passcode &&& 0x3FFF)

    # Chunk 3 (4 digits): passcode bits [26:14] (13 bits)
    chunk3 = (passcode >>> 14) &&& 0x1FFF

    code_without_check =
      Integer.to_string(digit1) <>
        String.pad_leading(Integer.to_string(chunk2), 5, "0") <>
        String.pad_leading(Integer.to_string(chunk3), 4, "0")

    check = verhoeff_generate(code_without_check)

    code_without_check <> Integer.to_string(check)
  end

  # ── Base-38 Encoding (chunked) ──────────────────────────────────────

  defp base38_encode_chunked(bytes) do
    bytes
    |> Enum.chunk_every(3)
    |> Enum.map(&encode_chunk/1)
    |> IO.iodata_to_binary()
  end

  defp encode_chunk(bytes) do
    # Treat bytes as little-endian integer
    value =
      bytes
      |> Enum.with_index()
      |> Enum.reduce(0, fn {byte, i}, acc -> acc ||| (byte <<< (i * 8)) end)

    # Number of base-38 characters for this chunk size
    num_chars =
      case length(bytes) do
        3 -> 5
        2 -> 4
        1 -> 2
      end

    do_base38(value, num_chars, [])
  end

  defp do_base38(_value, 0, acc), do: acc

  defp do_base38(value, remaining, acc) do
    char = elem(@base38_alphabet, rem(value, 38))
    do_base38(div(value, 38), remaining - 1, [acc, char])
  end

  # ── Verhoeff Algorithm ───────────────────────────────────────────────

  # Multiplication table for dihedral group D5 (tuples for O(1) lookup)
  @verhoeff_d {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9},
    {1, 2, 3, 4, 0, 6, 7, 8, 9, 5},
    {2, 3, 4, 0, 1, 7, 8, 9, 5, 6},
    {3, 4, 0, 1, 2, 8, 9, 5, 6, 7},
    {4, 0, 1, 2, 3, 9, 5, 6, 7, 8},
    {5, 9, 8, 7, 6, 0, 4, 3, 2, 1},
    {6, 5, 9, 8, 7, 1, 0, 4, 3, 2},
    {7, 6, 5, 9, 8, 2, 1, 0, 4, 3},
    {8, 7, 6, 5, 9, 3, 2, 1, 0, 4},
    {9, 8, 7, 6, 5, 4, 3, 2, 1, 0}
  }

  # Inverse table
  @verhoeff_inv {0, 4, 3, 2, 1, 5, 6, 7, 8, 9}

  # Permutation table
  @verhoeff_p {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9},
    {1, 5, 7, 6, 2, 8, 3, 0, 9, 4},
    {5, 8, 0, 3, 7, 9, 6, 1, 4, 2},
    {8, 9, 1, 6, 0, 4, 3, 5, 2, 7},
    {9, 4, 5, 3, 1, 2, 6, 8, 7, 0},
    {4, 2, 8, 6, 5, 7, 3, 9, 0, 1},
    {2, 7, 9, 3, 8, 0, 6, 4, 1, 5},
    {7, 0, 4, 6, 9, 1, 3, 2, 5, 8}
  }

  defp verhoeff_generate(number_string) do
    digits =
      (number_string <> "0")
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()

    c =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, i}, c ->
        p_val = @verhoeff_p |> elem(rem(i, 8)) |> elem(digit)
        @verhoeff_d |> elem(c) |> elem(p_val)
      end)

    elem(@verhoeff_inv, c)
  end
end
