defmodule Matterlix.TLVTest do
  use ExUnit.Case, async: true

  alias Matterlix.TLV

  # Helper: encode then decode, return decoded value
  defp roundtrip(input), do: TLV.decode(TLV.encode(input))

  # ── Unsigned Integers ──────────────────────────────────────────────

  describe "unsigned integers" do
    test "uint8: zero" do
      assert %{0 => 0} == roundtrip(%{0 => {:uint, 0}})
    end

    test "uint8: small value" do
      assert %{1 => 42} == roundtrip(%{1 => {:uint, 42}})
    end

    test "uint8: max (255)" do
      assert %{1 => 255} == roundtrip(%{1 => {:uint, 255}})
    end

    test "uint16: 256" do
      assert %{1 => 256} == roundtrip(%{1 => {:uint, 256}})
    end

    test "uint16: max (65535)" do
      assert %{1 => 65535} == roundtrip(%{1 => {:uint, 65535}})
    end

    test "uint32: 65536" do
      assert %{1 => 65536} == roundtrip(%{1 => {:uint, 65536}})
    end

    test "uint32: max (4294967295)" do
      assert %{1 => 4_294_967_295} == roundtrip(%{1 => {:uint, 4_294_967_295}})
    end

    test "uint64: 4294967296" do
      assert %{1 => 4_294_967_296} == roundtrip(%{1 => {:uint, 4_294_967_296}})
    end

    test "uint64: large value" do
      n = 18_446_744_073_709_551_615
      assert %{1 => ^n} = roundtrip(%{1 => {:uint, n}})
    end
  end

  # ── Signed Integers ────────────────────────────────────────────────

  describe "signed integers" do
    test "int8: zero" do
      assert %{1 => 0} == roundtrip(%{1 => {:int, 0}})
    end

    test "int8: positive" do
      assert %{1 => 42} == roundtrip(%{1 => {:int, 42}})
    end

    test "int8: negative" do
      assert %{1 => -1} == roundtrip(%{1 => {:int, -1}})
    end

    test "int8: max (127)" do
      assert %{1 => 127} == roundtrip(%{1 => {:int, 127}})
    end

    test "int8: min (-128)" do
      assert %{1 => -128} == roundtrip(%{1 => {:int, -128}})
    end

    test "int16: 128 (exceeds int8)" do
      assert %{1 => 128} == roundtrip(%{1 => {:int, 128}})
    end

    test "int16: -129 (exceeds int8)" do
      assert %{1 => -129} == roundtrip(%{1 => {:int, -129}})
    end

    test "int16: max (32767)" do
      assert %{1 => 32_767} == roundtrip(%{1 => {:int, 32_767}})
    end

    test "int16: min (-32768)" do
      assert %{1 => -32_768} == roundtrip(%{1 => {:int, -32_768}})
    end

    test "int32: 32768 (exceeds int16)" do
      assert %{1 => 32_768} == roundtrip(%{1 => {:int, 32_768}})
    end

    test "int32: max (2147483647)" do
      assert %{1 => 2_147_483_647} == roundtrip(%{1 => {:int, 2_147_483_647}})
    end

    test "int32: min (-2147483648)" do
      assert %{1 => -2_147_483_648} == roundtrip(%{1 => {:int, -2_147_483_648}})
    end

    test "int64: exceeds int32" do
      assert %{1 => 2_147_483_648} == roundtrip(%{1 => {:int, 2_147_483_648}})
    end

    test "int64: large negative" do
      assert %{1 => -2_147_483_649} == roundtrip(%{1 => {:int, -2_147_483_649}})
    end
  end

  # ── Booleans ───────────────────────────────────────────────────────

  describe "booleans" do
    test "true" do
      assert %{0 => true} == roundtrip(%{0 => {:bool, true}})
    end

    test "false" do
      assert %{0 => false} == roundtrip(%{0 => {:bool, false}})
    end
  end

  # ── Floating Point ─────────────────────────────────────────────────

  describe "float32" do
    test "zero" do
      assert %{1 => 0.0} == roundtrip(%{1 => {:float, 0.0}})
    end

    test "positive" do
      # float32 has limited precision; use approximate comparison
      %{1 => val} = roundtrip(%{1 => {:float, 1.5}})
      assert_in_delta val, 1.5, 0.001
    end

    test "negative" do
      %{1 => val} = roundtrip(%{1 => {:float, -3.14}})
      assert_in_delta val, -3.14, 0.01
    end
  end

  describe "float64 (double)" do
    test "zero" do
      assert %{1 => 0.0} == roundtrip(%{1 => {:double, 0.0}})
    end

    test "positive" do
      assert %{1 => 1.5} == roundtrip(%{1 => {:double, 1.5}})
    end

    test "negative" do
      assert %{1 => -3.14} == roundtrip(%{1 => {:double, -3.14}})
    end

    test "very small" do
      assert %{1 => 1.0e-100} == roundtrip(%{1 => {:double, 1.0e-100}})
    end

    test "very large" do
      assert %{1 => 1.0e100} == roundtrip(%{1 => {:double, 1.0e100}})
    end
  end

  # ── Strings ────────────────────────────────────────────────────────

  describe "UTF-8 strings" do
    test "empty string" do
      assert %{1 => ""} == roundtrip(%{1 => {:string, ""}})
    end

    test "simple string" do
      assert %{1 => "hello"} == roundtrip(%{1 => {:string, "hello"}})
    end

    test "unicode string" do
      assert %{1 => "héllo wörld"} == roundtrip(%{1 => {:string, "héllo wörld"}})
    end

    test "long string (>255 bytes, uses 2-byte length)" do
      s = String.duplicate("x", 300)
      assert %{1 => ^s} = roundtrip(%{1 => {:string, s}})
    end
  end

  # ── Byte Strings ───────────────────────────────────────────────────

  describe "byte strings" do
    test "empty bytes" do
      assert %{1 => <<>>} == roundtrip(%{1 => {:bytes, <<>>}})
    end

    test "small bytes" do
      assert %{1 => <<0xDE, 0xAD>>} == roundtrip(%{1 => {:bytes, <<0xDE, 0xAD>>}})
    end

    test "256 bytes (uses 2-byte length)" do
      b = :binary.copy(<<0xFF>>, 300)
      assert %{1 => ^b} = roundtrip(%{1 => {:bytes, b}})
    end
  end

  # ── Null ───────────────────────────────────────────────────────────

  describe "null" do
    test "null value" do
      assert %{1 => nil} == roundtrip(%{1 => :null})
    end
  end

  # ── Structs ────────────────────────────────────────────────────────

  describe "structs" do
    test "empty struct" do
      assert %{} == roundtrip(%{})
    end

    test "single field" do
      assert %{1 => 42} == roundtrip(%{1 => {:uint, 42}})
    end

    test "multiple fields" do
      input = %{0 => {:bool, true}, 1 => {:uint, 100}, 2 => {:string, "hi"}}
      assert %{0 => true, 1 => 100, 2 => "hi"} == roundtrip(input)
    end

    test "nested struct" do
      input = %{
        1 => {:struct, %{0 => {:uint, 5}, 1 => {:bool, false}}}
      }

      assert %{1 => %{0 => 5, 1 => false}} == roundtrip(input)
    end

    test "deeply nested structs" do
      input = %{
        0 => {:struct, %{
          0 => {:struct, %{
            0 => {:uint, 99}
          }}
        }}
      }

      assert %{0 => %{0 => %{0 => 99}}} == roundtrip(input)
    end
  end

  # ── Arrays ─────────────────────────────────────────────────────────

  describe "arrays" do
    test "empty array" do
      assert %{1 => []} == roundtrip(%{1 => {:array, []}})
    end

    test "single element" do
      assert %{1 => [42]} == roundtrip(%{1 => {:array, [{:uint, 42}]}})
    end

    test "multiple elements" do
      input = %{1 => {:array, [{:uint, 1}, {:uint, 2}, {:uint, 3}]}}
      assert %{1 => [1, 2, 3]} == roundtrip(input)
    end

    test "array of strings" do
      input = %{1 => {:array, [{:string, "a"}, {:string, "b"}]}}
      assert %{1 => ["a", "b"]} == roundtrip(input)
    end

    test "array of booleans" do
      input = %{1 => {:array, [{:bool, true}, {:bool, false}, {:bool, true}]}}
      assert %{1 => [true, false, true]} == roundtrip(input)
    end

    test "nested arrays" do
      input = %{
        1 => {:array, [
          {:array, [{:uint, 1}, {:uint, 2}]},
          {:array, [{:uint, 3}, {:uint, 4}]}
        ]}
      }

      assert %{1 => [[1, 2], [3, 4]]} == roundtrip(input)
    end

    test "array of structs" do
      input = %{
        1 => {:array, [
          {:struct, %{0 => {:uint, 1}, 1 => {:string, "a"}}},
          {:struct, %{0 => {:uint, 2}, 1 => {:string, "b"}}}
        ]}
      }

      assert %{1 => [%{0 => 1, 1 => "a"}, %{0 => 2, 1 => "b"}]} == roundtrip(input)
    end
  end

  # ── Lists ──────────────────────────────────────────────────────────

  describe "lists" do
    test "empty list" do
      assert %{1 => %{}} == roundtrip(%{1 => {:list, []}})
    end

    test "list with anonymous elements" do
      input = %{1 => {:list, [{:uint, 10}, {:string, "hi"}]}}
      assert %{1 => %{0 => 10, 1 => "hi"}} == roundtrip(input)
    end

    test "list with tagged elements (map form)" do
      input = %{1 => {:list, %{0 => {:uint, 10}, 1 => {:string, "hi"}}}}
      assert %{1 => %{0 => 10, 1 => "hi"}} == roundtrip(input)
    end
  end

  # ── Complex / Mixed Structures ─────────────────────────────────────

  describe "complex structures" do
    test "design doc example" do
      input = %{
        1 => {:uint, 42},
        2 => {:string, "hello"},
        3 => {:struct, %{
          0 => {:bool, true},
          1 => {:bytes, <<0xDE, 0xAD>>}
        }}
      }

      expected = %{
        1 => 42,
        2 => "hello",
        3 => %{0 => true, 1 => <<0xDE, 0xAD>>}
      }

      assert expected == roundtrip(input)
    end

    test "struct with all scalar types" do
      input = %{
        0 => {:uint, 255},
        1 => {:int, -100},
        2 => {:bool, true},
        3 => {:double, 3.14},
        4 => {:string, "test"},
        5 => {:bytes, <<1, 2, 3>>},
        6 => :null
      }

      result = roundtrip(input)
      assert result[0] == 255
      assert result[1] == -100
      assert result[2] == true
      assert_in_delta result[3], 3.14, 0.0001
      assert result[4] == "test"
      assert result[5] == <<1, 2, 3>>
      assert result[6] == nil
    end

    test "struct with array and nested struct" do
      input = %{
        0 => {:array, [{:uint, 1}, {:uint, 2}]},
        1 => {:struct, %{0 => {:string, "nested"}}},
        2 => :null
      }

      expected = %{
        0 => [1, 2],
        1 => %{0 => "nested"},
        2 => nil
      }

      assert expected == roundtrip(input)
    end

    test "many context tags" do
      input =
        for i <- 0..20, into: %{} do
          {i, {:uint, i * 10}}
        end

      result = roundtrip(input)

      for i <- 0..20 do
        assert result[i] == i * 10
      end
    end
  end

  # ── Binary Encoding Verification ───────────────────────────────────

  describe "encoding produces correct binary" do
    test "empty struct" do
      assert <<0x15, 0x18>> == TLV.encode(%{})
    end

    test "struct with uint8" do
      # 0x15 = anonymous struct
      # 0x24 = context tag (001_00100) + uint8 (0x04)
      # 0x01 = tag number 1
      # 0x2A = 42
      # 0x18 = end of container
      assert <<0x15, 0x24, 0x01, 0x2A, 0x18>> == TLV.encode(%{1 => {:uint, 42}})
    end

    test "struct with bool true" do
      # 0x29 = context tag (001_01001) + bool_true (0x09)
      # 0x00 = tag number 0
      assert <<0x15, 0x29, 0x00, 0x18>> == TLV.encode(%{0 => {:bool, true}})
    end

    test "struct with bool false" do
      # 0x28 = context tag (001_01000) + bool_false (0x08)
      assert <<0x15, 0x28, 0x00, 0x18>> == TLV.encode(%{0 => {:bool, false}})
    end

    test "struct with null" do
      # 0x34 = context tag (001_10100) + null (0x14)
      assert <<0x15, 0x34, 0x01, 0x18>> == TLV.encode(%{1 => :null})
    end

    test "struct with int8 negative" do
      # 0x20 = context tag (001_00000) + int8 (0x00)
      # 0x01 = tag number 1
      # 0xFF = -1 as signed int8
      assert <<0x15, 0x20, 0x01, 0xFF, 0x18>> == TLV.encode(%{1 => {:int, -1}})
    end

    test "struct with uint16" do
      # 0x25 = context tag + uint16 (0x05)
      # 0x01 = tag 1
      # 0x00, 0x01 = 256 little-endian
      assert <<0x15, 0x25, 0x01, 0x00, 0x01, 0x18>> == TLV.encode(%{1 => {:uint, 256}})
    end

    test "struct with string" do
      # 0x2C = context tag + utf8_1 (0x0C)
      # 0x01 = tag 1
      # 0x02 = length 2
      # "hi" = 0x68, 0x69
      assert <<0x15, 0x2C, 0x01, 0x02, ?h, ?i, 0x18>> == TLV.encode(%{1 => {:string, "hi"}})
    end

    test "struct with bytes" do
      # 0x30 = context tag + bytes_1 (0x10)
      # 0x01 = tag 1
      # 0x02 = length 2
      # 0xDE, 0xAD
      assert <<0x15, 0x30, 0x01, 0x02, 0xDE, 0xAD, 0x18>> ==
               TLV.encode(%{1 => {:bytes, <<0xDE, 0xAD>>}})
    end

    test "nested struct encoding" do
      encoded = TLV.encode(%{1 => {:struct, %{0 => {:uint, 5}}}})

      assert <<
               0x15,
               0x35, 0x01,
               0x24, 0x00, 0x05,
               0x18,
               0x18
             >> == encoded
    end

    test "array encoding" do
      encoded = TLV.encode(%{1 => {:array, [{:uint, 1}, {:uint, 2}]}})

      assert <<
               0x15,
               0x36, 0x01,
               0x04, 0x01,
               0x04, 0x02,
               0x18,
               0x18
             >> == encoded
    end

    test "fields are sorted by tag" do
      # Regardless of insertion order, tags should be sorted
      encoded = TLV.encode(%{2 => {:uint, 2}, 0 => {:uint, 0}, 1 => {:uint, 1}})

      assert <<
               0x15,
               0x24, 0x00, 0x00,
               0x24, 0x01, 0x01,
               0x24, 0x02, 0x02,
               0x18
             >> == encoded
    end
  end

  # ── Decoding Known Binaries ────────────────────────────────────────

  describe "decoding known binaries" do
    test "empty struct" do
      assert %{} == TLV.decode(<<0x15, 0x18>>)
    end

    test "struct with uint8" do
      assert %{1 => 42} == TLV.decode(<<0x15, 0x24, 0x01, 0x2A, 0x18>>)
    end

    test "struct with negative int8" do
      assert %{1 => -1} == TLV.decode(<<0x15, 0x20, 0x01, 0xFF, 0x18>>)
    end

    test "struct with bool true" do
      assert %{0 => true} == TLV.decode(<<0x15, 0x29, 0x00, 0x18>>)
    end

    test "struct with uint32" do
      # uint32, tag 1, value 100000 (0x000186A0 little-endian: A0 86 01 00)
      assert %{1 => 100_000} ==
               TLV.decode(<<0x15, 0x26, 0x01, 0xA0, 0x86, 0x01, 0x00, 0x18>>)
    end

    test "nested struct" do
      binary = <<0x15, 0x35, 0x01, 0x24, 0x00, 0x05, 0x18, 0x18>>
      assert %{1 => %{0 => 5}} == TLV.decode(binary)
    end

    test "array of uint8" do
      binary = <<0x15, 0x36, 0x01, 0x04, 0x0A, 0x04, 0x14, 0x18, 0x18>>
      assert %{1 => [10, 20]} == TLV.decode(binary)
    end
  end

  # ── Integer Size Selection ─────────────────────────────────────────

  describe "integer size selection" do
    test "uint uses smallest encoding" do
      # 42 fits in 1 byte -> uint8
      encoded = TLV.encode(%{0 => {:uint, 42}})
      # control byte for context uint8 = 0x24, 1 byte tag, 1 byte value
      assert byte_size(encoded) == 5

      # 256 needs 2 bytes -> uint16
      encoded = TLV.encode(%{0 => {:uint, 256}})
      assert byte_size(encoded) == 6

      # 70000 needs 4 bytes -> uint32
      encoded = TLV.encode(%{0 => {:uint, 70_000}})
      assert byte_size(encoded) == 8

      # >2^32 needs 8 bytes -> uint64
      encoded = TLV.encode(%{0 => {:uint, 5_000_000_000}})
      assert byte_size(encoded) == 12
    end

    test "int uses smallest encoding" do
      # 42 fits in 1 byte -> int8
      encoded = TLV.encode(%{0 => {:int, 42}})
      assert byte_size(encoded) == 5

      # 200 needs 2 bytes -> int16
      encoded = TLV.encode(%{0 => {:int, 200}})
      assert byte_size(encoded) == 6

      # 40000 needs 4 bytes -> int32
      encoded = TLV.encode(%{0 => {:int, 40_000}})
      assert byte_size(encoded) == 8

      # >2^31 needs 8 bytes -> int64
      encoded = TLV.encode(%{0 => {:int, 3_000_000_000}})
      assert byte_size(encoded) == 12
    end
  end

  # ── Edge Cases ─────────────────────────────────────────────────────

  describe "edge cases" do
    test "tag 0" do
      assert %{0 => 1} == roundtrip(%{0 => {:uint, 1}})
    end

    test "tag 255 (max context tag)" do
      assert %{255 => 1} == roundtrip(%{255 => {:uint, 1}})
    end

    test "empty string in struct" do
      assert %{0 => ""} == roundtrip(%{0 => {:string, ""}})
    end

    test "empty bytes in struct" do
      assert %{0 => <<>>} == roundtrip(%{0 => {:bytes, <<>>}})
    end

    test "struct with only null fields" do
      input = %{0 => :null, 1 => :null, 2 => :null}
      assert %{0 => nil, 1 => nil, 2 => nil} == roundtrip(input)
    end

    test "single-element struct" do
      assert %{0 => true} == roundtrip(%{0 => {:bool, true}})
    end

    test "array with single struct element" do
      input = %{0 => {:array, [{:struct, %{0 => {:uint, 1}}}]}}
      assert %{0 => [%{0 => 1}]} == roundtrip(input)
    end

    test "struct containing array containing struct" do
      input = %{
        0 => {:array, [
          {:struct, %{0 => {:uint, 1}, 1 => {:string, "a"}}},
          {:struct, %{0 => {:uint, 2}, 1 => {:string, "b"}}}
        ]}
      }

      expected = %{
        0 => [
          %{0 => 1, 1 => "a"},
          %{0 => 2, 1 => "b"}
        ]
      }

      assert expected == roundtrip(input)
    end
  end
end
