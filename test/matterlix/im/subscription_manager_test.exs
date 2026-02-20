defmodule Matterlix.IM.SubscriptionManagerTest do
  use ExUnit.Case, async: true

  alias Matterlix.IM.SubscriptionManager

  @paths [%{endpoint: 1, cluster: 6, attribute: 0}]

  describe "new/0" do
    test "creates empty state" do
      mgr = SubscriptionManager.new()
      assert mgr.subscriptions == %{}
      assert mgr.next_id == 1
      refute SubscriptionManager.active?(mgr)
    end
  end

  describe "subscribe/4" do
    test "registers subscription and returns incrementing IDs" do
      mgr = SubscriptionManager.new()

      {id1, mgr} = SubscriptionManager.subscribe(mgr, @paths, 0, 60)
      assert id1 == 1

      {id2, mgr} = SubscriptionManager.subscribe(mgr, @paths, 10, 120)
      assert id2 == 2

      assert SubscriptionManager.active?(mgr)
      assert length(SubscriptionManager.subscriptions(mgr)) == 2
    end

    test "stores paths and intervals" do
      mgr = SubscriptionManager.new()
      paths = [%{endpoint: 1, cluster: 6, attribute: 0}]

      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, paths, 5, 30)
      sub = SubscriptionManager.get(mgr, sub_id)

      assert sub.paths == paths
      assert sub.min_interval == 5
      assert sub.max_interval == 30
      assert sub.last_values == %{}
    end
  end

  describe "unsubscribe/2" do
    test "removes subscription" do
      mgr = SubscriptionManager.new()
      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, @paths, 0, 60)

      assert SubscriptionManager.active?(mgr)

      mgr = SubscriptionManager.unsubscribe(mgr, sub_id)
      refute SubscriptionManager.active?(mgr)
      assert SubscriptionManager.get(mgr, sub_id) == nil
    end

    test "unsubscribing non-existent ID is no-op" do
      mgr = SubscriptionManager.new()
      mgr = SubscriptionManager.unsubscribe(mgr, 999)
      refute SubscriptionManager.active?(mgr)
    end
  end

  describe "subscriptions/1" do
    test "lists all active subscriptions" do
      mgr = SubscriptionManager.new()
      {_id1, mgr} = SubscriptionManager.subscribe(mgr, @paths, 0, 60)
      {_id2, mgr} = SubscriptionManager.subscribe(mgr, @paths, 10, 120)

      subs = SubscriptionManager.subscriptions(mgr)
      assert length(subs) == 2
      ids = Enum.map(subs, & &1.id) |> Enum.sort()
      assert ids == [1, 2]
    end
  end

  describe "due_reports/2" do
    test "returns IDs when max_interval elapsed" do
      mgr = SubscriptionManager.new()
      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, @paths, 0, 10)

      # Get the subscription's last_report_at
      sub = SubscriptionManager.get(mgr, sub_id)
      future = sub.last_report_at + 11

      due = SubscriptionManager.due_reports(mgr, future)
      assert [{^sub_id, _paths}] = due
    end

    test "returns empty when interval not elapsed" do
      mgr = SubscriptionManager.new()
      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, @paths, 0, 60)

      sub = SubscriptionManager.get(mgr, sub_id)
      now = sub.last_report_at + 5  # only 5 seconds, need 60

      assert SubscriptionManager.due_reports(mgr, now) == []
    end

    test "multiple subscriptions with different intervals" do
      mgr = SubscriptionManager.new()
      {id1, mgr} = SubscriptionManager.subscribe(mgr, @paths, 0, 10)
      {_id2, mgr} = SubscriptionManager.subscribe(mgr, @paths, 0, 60)

      sub1 = SubscriptionManager.get(mgr, id1)
      now = sub1.last_report_at + 15  # 15s > 10s max for sub1, < 60s for sub2

      due = SubscriptionManager.due_reports(mgr, now)
      assert length(due) == 1
      [{due_id, _}] = due
      assert due_id == id1
    end
  end

  describe "record_report/4" do
    test "updates last_report_at and last_values" do
      mgr = SubscriptionManager.new()
      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, @paths, 0, 10)

      values = %{{1, 6, 0} => false}
      now = System.monotonic_time(:second) + 100

      mgr = SubscriptionManager.record_report(mgr, sub_id, values, now)

      sub = SubscriptionManager.get(mgr, sub_id)
      assert sub.last_report_at == now
      assert sub.last_values == values
    end

    test "recording for non-existent ID is no-op" do
      mgr = SubscriptionManager.new()
      mgr = SubscriptionManager.record_report(mgr, 999, %{}, 0)
      refute SubscriptionManager.active?(mgr)
    end

    test "record_report does not update last_sent_at" do
      mgr = SubscriptionManager.new()
      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, @paths, 5, 10)

      # Simulate a send at time 50
      mgr = SubscriptionManager.record_sent(mgr, sub_id, %{}, 50)

      # record_report at time 53 should not update last_sent_at
      mgr = SubscriptionManager.record_report(mgr, sub_id, %{{1, 6, 0} => true}, 53)

      sub = SubscriptionManager.get(mgr, sub_id)
      assert sub.last_report_at == 53
      assert sub.last_sent_at == 50
    end
  end

  describe "record_sent/4" do
    test "updates last_sent_at, last_report_at, and last_values" do
      mgr = SubscriptionManager.new()
      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, @paths, 5, 10)

      values = %{{1, 6, 0} => true}
      now = System.monotonic_time(:second) + 100

      mgr = SubscriptionManager.record_sent(mgr, sub_id, values, now)

      sub = SubscriptionManager.get(mgr, sub_id)
      assert sub.last_sent_at == now
      assert sub.last_report_at == now
      assert sub.last_values == values
    end

    test "recording sent for non-existent ID is no-op" do
      mgr = SubscriptionManager.new()
      mgr = SubscriptionManager.record_sent(mgr, 999, %{}, 0)
      refute SubscriptionManager.active?(mgr)
    end
  end

  describe "throttled?/3" do
    test "returns false when min_interval is 0" do
      mgr = SubscriptionManager.new()
      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, @paths, 0, 60)

      refute SubscriptionManager.throttled?(mgr, sub_id, System.monotonic_time(:second))
    end

    test "returns false for freshly created subscription (no report sent yet)" do
      mgr = SubscriptionManager.new()
      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, @paths, 60, 120)

      # Even with large min_interval, initial report is never throttled
      # because last_sent_at starts at 0
      refute SubscriptionManager.throttled?(mgr, sub_id, System.monotonic_time(:second))
    end

    test "returns true when min_interval has not elapsed since last send" do
      mgr = SubscriptionManager.new()
      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, @paths, 10, 60)

      # Simulate having sent a report at time 100
      mgr = SubscriptionManager.record_sent(mgr, sub_id, %{}, 100)

      # Only 5 seconds elapsed since send, min_interval is 10
      assert SubscriptionManager.throttled?(mgr, sub_id, 105)
    end

    test "returns false when min_interval has elapsed since last send" do
      mgr = SubscriptionManager.new()
      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, @paths, 10, 60)

      # Simulate having sent a report at time 100
      mgr = SubscriptionManager.record_sent(mgr, sub_id, %{}, 100)

      # 15 seconds elapsed since send, min_interval is 10
      refute SubscriptionManager.throttled?(mgr, sub_id, 115)
    end

    test "returns false for non-existent subscription" do
      mgr = SubscriptionManager.new()
      refute SubscriptionManager.throttled?(mgr, 999, 0)
    end

    test "respects record_sent updating last_sent_at" do
      mgr = SubscriptionManager.new()
      {sub_id, mgr} = SubscriptionManager.subscribe(mgr, @paths, 10, 60)

      send_time = 100

      # Send a report at send_time
      mgr = SubscriptionManager.record_sent(mgr, sub_id, %{}, send_time)

      # 5 seconds after send — throttled
      assert SubscriptionManager.throttled?(mgr, sub_id, send_time + 5)

      # 10 seconds after send — not throttled
      refute SubscriptionManager.throttled?(mgr, sub_id, send_time + 10)
    end
  end

  describe "unsubscribe_all/1" do
    test "removes all subscriptions" do
      mgr = SubscriptionManager.new()
      {_id1, mgr} = SubscriptionManager.subscribe(mgr, @paths, 0, 60)
      {_id2, mgr} = SubscriptionManager.subscribe(mgr, @paths, 10, 120)
      {_id3, mgr} = SubscriptionManager.subscribe(mgr, @paths, 5, 30)

      assert SubscriptionManager.active?(mgr)
      assert length(SubscriptionManager.subscriptions(mgr)) == 3

      mgr = SubscriptionManager.unsubscribe_all(mgr)
      refute SubscriptionManager.active?(mgr)
      assert SubscriptionManager.subscriptions(mgr) == []
    end

    test "unsubscribe_all on empty state is no-op" do
      mgr = SubscriptionManager.new()
      mgr = SubscriptionManager.unsubscribe_all(mgr)
      refute SubscriptionManager.active?(mgr)
    end
  end
end
