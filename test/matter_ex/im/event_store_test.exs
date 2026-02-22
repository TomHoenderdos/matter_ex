defmodule MatterEx.IM.EventStoreTest do
  use ExUnit.Case, async: true

  alias MatterEx.IM.EventStore

  setup do
    name = :"event_store_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = EventStore.start_link(name: name)
    %{store: name}
  end

  describe "emit and read" do
    test "emits and reads an event", %{store: store} do
      :ok = EventStore.emit(store, 0, 0x0028, 0x00, 2, %{0 => {:uint, 1}})

      events = EventStore.read(store, [])
      assert length(events) == 1

      [event] = events
      assert event.number == 0
      assert event.endpoint == 0
      assert event.cluster == 0x0028
      assert event.event == 0x00
      assert event.priority == 2
      assert event.data == %{0 => {:uint, 1}}
    end

    test "event numbers are monotonically increasing", %{store: store} do
      :ok = EventStore.emit(store, 0, 0x0028, 0x00, 2, %{})
      :ok = EventStore.emit(store, 1, 0x0006, 0x00, 1, %{})
      :ok = EventStore.emit(store, 0, 0x0028, 0x01, 2, %{})

      events = EventStore.read(store, [])
      numbers = Enum.map(events, & &1.number)
      assert numbers == [0, 1, 2]
    end

    test "read with event_min filter", %{store: store} do
      :ok = EventStore.emit(store, 0, 0x0028, 0x00, 2, %{})
      :ok = EventStore.emit(store, 0, 0x0028, 0x01, 2, %{})
      :ok = EventStore.emit(store, 1, 0x0006, 0x00, 1, %{})

      events = EventStore.read(store, [], 2)
      assert length(events) == 1
      assert hd(events).number == 2
    end

    test "read with path filter", %{store: store} do
      :ok = EventStore.emit(store, 0, 0x0028, 0x00, 2, %{})
      :ok = EventStore.emit(store, 1, 0x0006, 0x00, 1, %{})

      events = EventStore.read(store, [%{endpoint: 0, cluster: 0x0028, event: 0x00}])
      assert length(events) == 1
      assert hd(events).cluster == 0x0028
    end

    test "read with wildcard path (endpoint only)", %{store: store} do
      :ok = EventStore.emit(store, 0, 0x0028, 0x00, 2, %{})
      :ok = EventStore.emit(store, 0, 0x0028, 0x01, 2, %{})
      :ok = EventStore.emit(store, 1, 0x0006, 0x00, 1, %{})

      events = EventStore.read(store, [%{endpoint: 0}])
      assert length(events) == 2
    end

    test "empty store returns empty list", %{store: store} do
      assert EventStore.read(store, []) == []
    end
  end

  describe "eviction" do
    test "evicts lowest priority events when buffer is full", %{store: store} do
      # Fill the buffer (64 events) with low priority
      for i <- 0..63 do
        :ok = EventStore.emit(store, 0, 0x0028, 0x00, 0, %{i: i})
      end

      assert length(EventStore.read(store, [])) == 64

      # Add one more high priority — should evict one low priority
      :ok = EventStore.emit(store, 0, 0x0028, 0x00, 2, %{critical: true})

      events = EventStore.read(store, [])
      assert length(events) == 64

      # The critical event should be present
      assert Enum.any?(events, fn e -> e.data == %{critical: true} end)
    end
  end
end
