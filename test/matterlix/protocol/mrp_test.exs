defmodule Matterlix.Protocol.MRPTest do
  use ExUnit.Case, async: true

  alias Matterlix.Protocol.MRP

  # ── new/1 ───────────────────────────────────────────────────────

  describe "new/1" do
    test "defaults to active mode" do
      mrp = MRP.new()
      assert mrp.mode == :active
      assert mrp.pending == %{}
    end

    test "accepts idle mode" do
      mrp = MRP.new(mode: :idle)
      assert mrp.mode == :idle
    end
  end

  # ── record_send/3 ──────────────────────────────────────────────

  describe "record_send/3" do
    test "adds exchange to pending" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      assert MRP.pending?(mrp, 1)
    end

    test "records attempt as 0" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      assert mrp.pending[1].attempt == 0
    end

    test "multiple exchanges tracked independently" do
      mrp =
        MRP.new()
        |> MRP.record_send(1, <<"msg1">>)
        |> MRP.record_send(2, <<"msg2">>)

      assert MRP.pending?(mrp, 1)
      assert MRP.pending?(mrp, 2)
    end
  end

  # ── on_timeout/3 ───────────────────────────────────────────────

  describe "on_timeout/3" do
    test "attempt 0: returns :retransmit with message" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      assert {:retransmit, <<"msg">>, mrp2} = MRP.on_timeout(mrp, 1, 0)
      assert mrp2.pending[1].attempt == 1
    end

    test "attempts 1-3: returns :retransmit" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 0)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 1)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 2)
      assert {:retransmit, <<"msg">>, _} = MRP.on_timeout(mrp, 1, 3)
    end

    test "attempt 4 (5th transmission): returns :give_up" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 0)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 1)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 2)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 3)
      assert {:give_up, mrp2} = MRP.on_timeout(mrp, 1, 4)
      refute MRP.pending?(mrp2, 1)
    end

    test "unknown exchange returns :already_acked" do
      mrp = MRP.new()
      assert {:already_acked, ^mrp} = MRP.on_timeout(mrp, 99, 0)
    end

    test "stale timer (attempt mismatch) returns :already_acked" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 0)
      # Timer for attempt 0 fires again (stale) — attempt is now 1
      assert {:already_acked, _} = MRP.on_timeout(mrp, 1, 0)
    end

    test "after give_up, exchange removed from pending" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 0)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 1)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 2)
      {:retransmit, _, mrp} = MRP.on_timeout(mrp, 1, 3)
      {:give_up, mrp} = MRP.on_timeout(mrp, 1, 4)
      refute MRP.pending?(mrp, 1)
    end
  end

  # ── on_ack/2 ───────────────────────────────────────────────────

  describe "on_ack/2" do
    test "known exchange: acknowledged and removed" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      assert {:ok, mrp2} = MRP.on_ack(mrp, 1)
      refute MRP.pending?(mrp2, 1)
    end

    test "unknown exchange returns :not_found" do
      mrp = MRP.new()
      assert {:error, :not_found} = MRP.on_ack(mrp, 99)
    end

    test "double ack returns :not_found on second" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      {:ok, mrp} = MRP.on_ack(mrp, 1)
      assert {:error, :not_found} = MRP.on_ack(mrp, 1)
    end

    test "ack prevents future retransmissions" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      {:ok, mrp} = MRP.on_ack(mrp, 1)
      assert {:already_acked, _} = MRP.on_timeout(mrp, 1, 0)
    end
  end

  # ── pending?/2 ─────────────────────────────────────────────────

  describe "pending?/2" do
    test "true when exchange is pending" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      assert MRP.pending?(mrp, 1)
    end

    test "false when exchange not known" do
      mrp = MRP.new()
      refute MRP.pending?(mrp, 1)
    end

    test "false after on_ack" do
      mrp = MRP.new() |> MRP.record_send(1, <<"msg">>)
      {:ok, mrp} = MRP.on_ack(mrp, 1)
      refute MRP.pending?(mrp, 1)
    end
  end

  # ── backoff_ms/3 ───────────────────────────────────────────────

  describe "backoff_ms/3" do
    test "attempt 0 active deterministic" do
      mrp = MRP.new(mode: :active)
      # 300 * 1.1 * 1.6^0 = 330
      assert MRP.backoff_ms(mrp, 0, deterministic: true) == 330
    end

    test "attempt 0 idle deterministic" do
      mrp = MRP.new(mode: :idle)
      # 500 * 1.1 * 1.6^0 = 550
      assert MRP.backoff_ms(mrp, 0, deterministic: true) == 550
    end

    test "backoff grows with each attempt" do
      mrp = MRP.new(mode: :active)

      values =
        Enum.map(0..4, fn attempt ->
          MRP.backoff_ms(mrp, attempt, deterministic: true)
        end)

      # Each value should be larger than the previous
      assert values == Enum.sort(values)
      assert Enum.uniq(values) == values
    end

    test "attempt progression active deterministic" do
      mrp = MRP.new(mode: :active)
      # 300 * 1.1 * 1.6^n
      assert MRP.backoff_ms(mrp, 0, deterministic: true) == 330
      assert MRP.backoff_ms(mrp, 1, deterministic: true) == 528
      assert MRP.backoff_ms(mrp, 2, deterministic: true) == 844
      assert MRP.backoff_ms(mrp, 3, deterministic: true) == 1351
    end

    test "with jitter is >= deterministic value" do
      mrp = MRP.new(mode: :active)
      deterministic = MRP.backoff_ms(mrp, 0, deterministic: true)
      jittered = MRP.backoff_ms(mrp, 0)
      assert jittered >= deterministic
    end

    test "with jitter is <= deterministic * 1.25" do
      mrp = MRP.new(mode: :active)
      deterministic = MRP.backoff_ms(mrp, 0, deterministic: true)

      # Run multiple times to check the upper bound
      for _ <- 1..100 do
        jittered = MRP.backoff_ms(mrp, 0)
        assert jittered <= trunc(deterministic * 1.25) + 1
      end
    end
  end

  # ── Constants ──────────────────────────────────────────────────

  describe "constants" do
    test "ack_timeout_ms is 200" do
      assert MRP.ack_timeout_ms() == 200
    end

    test "max_transmissions is 5" do
      assert MRP.max_transmissions() == 5
    end
  end
end
