defmodule MatterEx.IM.RouterTest do
  use ExUnit.Case

  alias MatterEx.IM
  alias MatterEx.IM.Router

  defmodule FabricDevice do
    use MatterEx.Device,
      vendor_name: "TestCo",
      product_name: "FabricTest",
      vendor_id: 0xFFF1,
      product_id: 0x8001

    endpoint 1, device_type: 0x0100 do
      cluster(MatterEx.Cluster.OnOff)
    end
  end

  setup do
    start_supervised!(FabricDevice)
    :ok
  end

  # ── Fabric-Scoped Attribute Tests ──────────────────────────────

  describe "fabric-scoped reads" do
    test "OperationalCredentials current_fabric_index reports the CASE session fabric" do
      acl_name = FabricDevice.__process_name__(0, :access_control)

      GenServer.call(
        acl_name,
        {:write_attribute, :acl,
         [
           %{privilege: 5, auth_mode: 2, subjects: [100], targets: nil, fabric_index: 1}
         ]}
      )

      report =
        Router.handle_read(
          FabricDevice,
          %IM.ReadRequest{attribute_paths: [%{endpoint: 0, cluster: 0x003E, attribute: 5}]},
          %{auth_mode: :case, subject: 100, fabric_index: 1}
        )

      [{:data, data}] = report.attribute_reports
      assert data.value == {:uint8, 1}
    end

    test "ACL read filters by requester's fabric_index" do
      acl_name = FabricDevice.__process_name__(0, :access_control)

      # Write entries for two different fabrics
      entries = [
        %{privilege: 5, auth_mode: 2, subjects: [100], targets: nil, fabric_index: 1},
        %{privilege: 3, auth_mode: 2, subjects: [200], targets: nil, fabric_index: 2}
      ]

      GenServer.call(acl_name, {:write_attribute, :acl, entries})

      # Read as fabric 1 — should only see fabric 1 entries
      context1 = %{auth_mode: :case, subject: 100, fabric_index: 1}

      report1 =
        Router.handle_read(
          FabricDevice,
          %IM.ReadRequest{attribute_paths: [%{endpoint: 0, cluster: 0x001F, attribute: 0}]},
          context1
        )

      [{:data, data1}] = report1.attribute_reports
      {:array, values1} = data1.value
      assert length(values1) == 1

      # Read as fabric 2 — should only see fabric 2 entries
      context2 = %{auth_mode: :case, subject: 200, fabric_index: 2}

      report2 =
        Router.handle_read(
          FabricDevice,
          %IM.ReadRequest{attribute_paths: [%{endpoint: 0, cluster: 0x001F, attribute: 0}]},
          context2
        )

      [{:data, data2}] = report2.attribute_reports
      {:array, values2} = data2.value
      assert length(values2) == 1
    end

    test "PASE reads bypass fabric filtering (sees all entries)" do
      acl_name = FabricDevice.__process_name__(0, :access_control)

      entries = [
        %{privilege: 5, auth_mode: 2, subjects: [100], targets: nil, fabric_index: 1},
        %{privilege: 3, auth_mode: 2, subjects: [200], targets: nil, fabric_index: 2}
      ]

      GenServer.call(acl_name, {:write_attribute, :acl, entries})

      # PASE context (fabric_index: 0) — should see all
      pase_context = %{auth_mode: :pase, subject: 0, fabric_index: 0}

      report =
        Router.handle_read(
          FabricDevice,
          %IM.ReadRequest{attribute_paths: [%{endpoint: 0, cluster: 0x001F, attribute: 0}]},
          pase_context
        )

      [{:data, data}] = report.attribute_reports
      {:array, values} = data.value
      assert length(values) == 2
    end

    test "non-fabric-scoped attributes are not filtered" do
      # OnOff is not fabric-scoped — all contexts see the same value
      context = %{auth_mode: :case, subject: 100, fabric_index: 1}

      # Seed ACL so CASE read is allowed
      acl_name = FabricDevice.__process_name__(0, :access_control)

      GenServer.call(
        acl_name,
        {:write_attribute, :acl,
         [
           %{privilege: 5, auth_mode: 2, subjects: [100], targets: nil, fabric_index: 1}
         ]}
      )

      report =
        Router.handle_read(
          FabricDevice,
          %IM.ReadRequest{attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0}]},
          context
        )

      [{:data, data}] = report.attribute_reports
      assert data.value == {:bool, false}
    end
  end

  describe "fabric-scoped writes" do
    test "writing ACL for one fabric preserves other fabric's entries" do
      acl_name = FabricDevice.__process_name__(0, :access_control)

      # Pre-seed ACL with entries for both fabrics
      GenServer.call(
        acl_name,
        {:write_attribute, :acl,
         [
           %{privilege: 5, auth_mode: 2, subjects: [100], targets: nil, fabric_index: 1},
           %{privilege: 5, auth_mode: 2, subjects: [200], targets: nil, fabric_index: 2}
         ]}
      )

      # Write new ACL for fabric 1 via Router (which merges)
      context = %{auth_mode: :case, subject: 100, fabric_index: 1}
      new_entry = %{privilege: 3, auth_mode: 2, subjects: [100], targets: nil, fabric_index: 1}

      write_req = %IM.WriteRequest{
        write_requests: [
          %{
            path: %{endpoint: 0, cluster: 0x001F, attribute: 0},
            value: [new_entry]
          }
        ]
      }

      _resp = Router.handle(FabricDevice, :write_request, write_req, context)

      # Verify: fabric 2's entry is preserved
      {:ok, all_entries} = GenServer.call(acl_name, {:read_attribute, :acl})
      assert length(all_entries) == 2

      fabric1 = Enum.filter(all_entries, &(&1[:fabric_index] == 1))
      fabric2 = Enum.filter(all_entries, &(&1[:fabric_index] == 2))

      assert length(fabric1) == 1
      assert hd(fabric1).privilege == 3
      assert length(fabric2) == 1
      assert hd(fabric2).subjects == [200]
    end

    test "writing ACL stamps missing fabric index on new entries" do
      acl_name = FabricDevice.__process_name__(0, :access_control)

      GenServer.call(
        acl_name,
        {:write_attribute, :acl,
         [
           %{privilege: 5, auth_mode: 2, subjects: [100], targets: nil, fabric_index: 1}
         ]}
      )

      context = %{auth_mode: :case, subject: 100, fabric_index: 1}
      new_entry = %{1 => 5, 2 => 2, 3 => [100], 4 => nil}

      write_req = %IM.WriteRequest{
        write_requests: [
          %{
            path: %{endpoint: 0, cluster: 0x001F, attribute: 0},
            value: [new_entry]
          }
        ]
      }

      _resp = Router.handle(FabricDevice, :write_request, write_req, context)

      {:ok, [stored]} = GenServer.call(acl_name, {:read_attribute, :acl})
      assert stored[254] == 1
      assert :allow == MatterEx.ACL.check(context, [stored], :view, {1, 0x0006})

      report =
        Router.handle_read(
          FabricDevice,
          %IM.ReadRequest{attribute_paths: [%{endpoint: 0, cluster: 0x001F, attribute: 0}]},
          context
        )

      [{:data, data}] = report.attribute_reports

      assert {:array,
              [
                {:struct,
                 %{
                   1 => {:uint, 5},
                   2 => {:uint, 2},
                   3 => {:array, [{:uint, 100}]},
                   4 => :null,
                   254 => {:uint, 1}
                 }}
              ]} = data.value
    end
  end

  # ── cluster_versions (subscription poll gate) ──────────────────

  describe "cluster_versions/2" do
    test "returns an integer DataVersion for each cluster a wildcard covers" do
      versions = Router.cluster_versions(FabricDevice, [%{}])

      # OnOff on endpoint 1 is covered; all values are integer versions.
      assert Map.has_key?(versions, {1, 0x0006})
      assert map_size(versions) > 1
      assert Enum.all?(Map.values(versions), &is_integer/1)
    end

    test "a concrete path covers only that cluster" do
      versions =
        Router.cluster_versions(FabricDevice, [%{endpoint: 1, cluster: 0x0006, attribute: 0}])

      assert Map.keys(versions) == [{1, 0x0006}]
    end

    test "a write bumps only the written cluster's version" do
      before = Router.cluster_versions(FabricDevice, [%{}])

      on_off = FabricDevice.__process_name__(1, :on_off)
      :ok = GenServer.call(on_off, {:write_attribute, :on_off, true})

      after_write = Router.cluster_versions(FabricDevice, [%{}])

      assert after_write[{1, 0x0006}] == before[{1, 0x0006}] + 1
      # Every other cluster is unchanged — so the poll gate skips the full read.
      others = Map.delete(after_write, {1, 0x0006})
      assert Enum.all?(others, fn {key, version} -> before[key] == version end)
    end

    test "an invoke that changes state bumps the cluster version" do
      path = [%{endpoint: 1, cluster: 0x0006, attribute: 0}]
      before = Router.cluster_versions(FabricDevice, path)

      on_off = FabricDevice.__process_name__(1, :on_off)
      {:ok, _} = GenServer.call(on_off, {:invoke_command, :on, %{}, %{auth_mode: :pase}})

      assert Router.cluster_versions(FabricDevice, path)[{1, 0x0006}] > before[{1, 0x0006}]
    end

    test "nil device returns an empty map" do
      assert Router.cluster_versions(nil, [%{}]) == %{}
    end
  end
end
