defmodule Matterlix.Protocol.CounterTest do
  use ExUnit.Case, async: true

  alias Matterlix.Protocol.Counter

  # ── next/1 ──────────────────────────────────────────────────────

  describe "next/1" do
    test "returns current counter and increments" do
      c = Counter.new(100)
      {val, c2} = Counter.next(c)
      assert val == 100
      {val2, _c3} = Counter.next(c2)
      assert val2 == 101
    end

    test "counter increments across multiple calls" do
      c = Counter.new(0)

      {vals, _} =
        Enum.map_reduce(1..10, c, fn _i, acc ->
          Counter.next(acc)
        end)

      assert vals == Enum.to_list(0..9)
    end

    test "counter wraps at 0xFFFFFFFF" do
      c = Counter.new(0xFFFFFFFF)
      {val, c2} = Counter.next(c)
      assert val == 0xFFFFFFFF
      {val2, _c3} = Counter.next(c2)
      assert val2 == 0
    end
  end

  # ── new/0 ───────────────────────────────────────────────────────

  describe "new/0" do
    test "random initial counter" do
      c1 = Counter.new()
      c2 = Counter.new()
      # Extremely unlikely to be the same
      assert c1.local_counter != c2.local_counter
    end
  end

  # ── check_and_update/3 ─────────────────────────────────────────

  describe "check_and_update/3" do
    test "first message from peer is accepted" do
      c = Counter.new(0)
      assert {:ok, _c} = Counter.check_and_update(c, :peer1, 42)
    end

    test "same counter twice is :duplicate" do
      c = Counter.new(0)
      {:ok, c} = Counter.check_and_update(c, :peer1, 42)
      assert {:error, :duplicate} = Counter.check_and_update(c, :peer1, 42)
    end

    test "higher counter advances window" do
      c = Counter.new(0)
      {:ok, c} = Counter.check_and_update(c, :peer1, 10)
      {:ok, c} = Counter.check_and_update(c, :peer1, 20)
      {:ok, _c} = Counter.check_and_update(c, :peer1, 30)
    end

    test "lower counter within window is accepted (out-of-order)" do
      c = Counter.new(0)
      {:ok, c} = Counter.check_and_update(c, :peer1, 20)
      # 15 is within the 32-element window (20 - 15 = 5 < 32)
      {:ok, _c} = Counter.check_and_update(c, :peer1, 15)
    end

    test "lower counter already seen within window is :duplicate" do
      c = Counter.new(0)
      {:ok, c} = Counter.check_and_update(c, :peer1, 20)
      {:ok, c} = Counter.check_and_update(c, :peer1, 15)
      assert {:error, :duplicate} = Counter.check_and_update(c, :peer1, 15)
    end

    test "counter more than 32 behind max is :too_old" do
      c = Counter.new(0)
      {:ok, c} = Counter.check_and_update(c, :peer1, 100)
      # 100 - 67 = 33 >= 32 => too old
      assert {:error, :too_old} = Counter.check_and_update(c, :peer1, 67)
    end

    test "different peers have independent windows" do
      c = Counter.new(0)
      {:ok, c} = Counter.check_and_update(c, :peer1, 42)
      # Same counter but different peer — accepted
      {:ok, _c} = Counter.check_and_update(c, :peer2, 42)
    end

    test "window boundary: exactly 31 positions back is accepted" do
      c = Counter.new(0)
      {:ok, c} = Counter.check_and_update(c, :peer1, 50)
      # 50 - 19 = 31, which is < 32 => inside window
      {:ok, _c} = Counter.check_and_update(c, :peer1, 19)
    end

    test "window boundary: 32 positions back is :too_old" do
      c = Counter.new(0)
      {:ok, c} = Counter.check_and_update(c, :peer1, 50)
      # 50 - 18 = 32, which is >= 32 => too old
      assert {:error, :too_old} = Counter.check_and_update(c, :peer1, 18)
    end

    test "sequential counters all accepted" do
      c = Counter.new(0)

      c =
        Enum.reduce(1..100, c, fn i, acc ->
          {:ok, new_acc} = Counter.check_and_update(acc, :peer1, i)
          new_acc
        end)

      # The 100th counter should now be the max; trying it again = duplicate
      assert {:error, :duplicate} = Counter.check_and_update(c, :peer1, 100)
    end

    test "complex out-of-order scenario" do
      c = Counter.new(0)
      # Receive: 10, 8, 12, 9, 11, 8 (dup), 10 (dup)
      {:ok, c} = Counter.check_and_update(c, :p, 10)
      {:ok, c} = Counter.check_and_update(c, :p, 8)
      {:ok, c} = Counter.check_and_update(c, :p, 12)
      {:ok, c} = Counter.check_and_update(c, :p, 9)
      {:ok, c} = Counter.check_and_update(c, :p, 11)
      assert {:error, :duplicate} = Counter.check_and_update(c, :p, 8)
      assert {:error, :duplicate} = Counter.check_and_update(c, :p, 10)
    end
  end
end
