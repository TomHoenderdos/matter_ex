defmodule Matterlix.ClusterTest do
  use ExUnit.Case, async: true

  alias Matterlix.Cluster.OnOff
  alias Matterlix.Cluster.Descriptor
  alias Matterlix.Cluster.BasicInformation

  # ── Cluster macro metadata ────────────────────────────────────

  describe "cluster metadata" do
    test "OnOff cluster_id and name" do
      assert OnOff.cluster_id() == 0x0006
      assert OnOff.cluster_name() == :on_off
    end

    test "OnOff attribute_defs" do
      defs = OnOff.attribute_defs()
      assert length(defs) == 2

      on_off_attr = Enum.find(defs, &(&1.name == :on_off))
      assert on_off_attr.id == 0x0000
      assert on_off_attr.type == :boolean
      assert on_off_attr.default == false
      assert on_off_attr.writable == true

      rev_attr = Enum.find(defs, &(&1.name == :cluster_revision))
      assert rev_attr.id == 0xFFFD
      assert rev_attr.writable == false
    end

    test "OnOff command_defs" do
      defs = OnOff.command_defs()
      assert length(defs) == 3
      assert Enum.find(defs, &(&1.name == :off)).id == 0x00
      assert Enum.find(defs, &(&1.name == :on)).id == 0x01
      assert Enum.find(defs, &(&1.name == :toggle)).id == 0x02
    end

    test "Descriptor cluster_id and name" do
      assert Descriptor.cluster_id() == 0x001D
      assert Descriptor.cluster_name() == :descriptor
    end

    test "BasicInformation cluster_id and name" do
      assert BasicInformation.cluster_id() == 0x0028
      assert BasicInformation.cluster_name() == :basic_information
    end
  end

  # ── OnOff GenServer ───────────────────────────────────────────

  describe "OnOff GenServer" do
    setup do
      name = :"on_off_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = OnOff.start_link(name: name)
      %{pid: pid, name: name}
    end

    test "initial state defaults", %{name: name} do
      assert {:ok, false} = GenServer.call(name, {:read_attribute, :on_off})
      assert {:ok, 4} = GenServer.call(name, {:read_attribute, :cluster_revision})
    end

    test "read unknown attribute", %{name: name} do
      assert {:error, :unsupported_attribute} =
               GenServer.call(name, {:read_attribute, :bogus})
    end

    test "write writable attribute", %{name: name} do
      assert :ok = GenServer.call(name, {:write_attribute, :on_off, true})
      assert {:ok, true} = GenServer.call(name, {:read_attribute, :on_off})
    end

    test "write read-only attribute fails", %{name: name} do
      assert {:error, :unsupported_write} =
               GenServer.call(name, {:write_attribute, :cluster_revision, 99})
    end

    test "write unknown attribute fails", %{name: name} do
      assert {:error, :unsupported_attribute} =
               GenServer.call(name, {:write_attribute, :bogus, 1})
    end

    test "invoke :on command", %{name: name} do
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :on, %{}})
      assert {:ok, true} = GenServer.call(name, {:read_attribute, :on_off})
    end

    test "invoke :off command", %{name: name} do
      GenServer.call(name, {:invoke_command, :on, %{}})
      assert {:ok, nil} = GenServer.call(name, {:invoke_command, :off, %{}})
      assert {:ok, false} = GenServer.call(name, {:read_attribute, :on_off})
    end

    test "invoke :toggle command", %{name: name} do
      assert {:ok, false} = GenServer.call(name, {:read_attribute, :on_off})
      GenServer.call(name, {:invoke_command, :toggle, %{}})
      assert {:ok, true} = GenServer.call(name, {:read_attribute, :on_off})
      GenServer.call(name, {:invoke_command, :toggle, %{}})
      assert {:ok, false} = GenServer.call(name, {:read_attribute, :on_off})
    end

    test "invoke unknown command fails", %{name: name} do
      assert {:error, :unsupported_command} =
               GenServer.call(name, {:invoke_command, :bogus, %{}})
    end
  end

  # ── Descriptor GenServer ──────────────────────────────────────

  describe "Descriptor GenServer" do
    setup do
      name = :"descriptor_test_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Descriptor.start_link(
          name: name,
          device_type_list: [%{device_type: 0x0100, revision: 1}],
          server_list: [0x0006, 0x001D],
          parts_list: [1, 2]
        )

      %{pid: pid, name: name}
    end

    test "init populates from opts", %{name: name} do
      assert {:ok, [%{device_type: 0x0100, revision: 1}]} =
               GenServer.call(name, {:read_attribute, :device_type_list})

      assert {:ok, [0x0006, 0x001D]} =
               GenServer.call(name, {:read_attribute, :server_list})

      assert {:ok, [1, 2]} =
               GenServer.call(name, {:read_attribute, :parts_list})
    end
  end

  # ── BasicInformation GenServer ────────────────────────────────

  describe "BasicInformation GenServer" do
    setup do
      name = :"basic_info_test_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        BasicInformation.start_link(
          name: name,
          vendor_name: "TestCo",
          vendor_id: 0xFFF1,
          product_name: "TestLight",
          product_id: 0x8001
        )

      %{pid: pid, name: name}
    end

    test "init populates from opts", %{name: name} do
      assert {:ok, "TestCo"} =
               GenServer.call(name, {:read_attribute, :vendor_name})

      assert {:ok, 0xFFF1} =
               GenServer.call(name, {:read_attribute, :vendor_id})

      assert {:ok, "TestLight"} =
               GenServer.call(name, {:read_attribute, :product_name})

      assert {:ok, 0x8001} =
               GenServer.call(name, {:read_attribute, :product_id})
    end

    test "node_label is writable", %{name: name} do
      assert :ok = GenServer.call(name, {:write_attribute, :node_label, "my light"})
      assert {:ok, "my light"} = GenServer.call(name, {:read_attribute, :node_label})
    end

    test "vendor_name is read-only", %{name: name} do
      assert {:error, :unsupported_write} =
               GenServer.call(name, {:write_attribute, :vendor_name, "hack"})
    end
  end
end
