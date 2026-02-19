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
  end
end
