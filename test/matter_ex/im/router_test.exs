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
      cluster MatterEx.Cluster.OnOff
    end
  end

  setup do
    start_supervised!(FabricDevice)
    :ok
  end

  # ── Fabric-Scoped Attribute Tests ──────────────────────────────

  describe "fabric-scoped reads" do
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
      report1 = Router.handle_read(FabricDevice,
        %IM.ReadRequest{attribute_paths: [%{endpoint: 0, cluster: 0x001F, attribute: 0}]},
        context1
      )

      [{:data, data1}] = report1.attribute_reports
      {:array, values1} = data1.value
      assert length(values1) == 1

      # Read as fabric 2 — should only see fabric 2 entries
      context2 = %{auth_mode: :case, subject: 200, fabric_index: 2}
      report2 = Router.handle_read(FabricDevice,
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
      report = Router.handle_read(FabricDevice,
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
      GenServer.call(acl_name, {:write_attribute, :acl, [
        %{privilege: 5, auth_mode: 2, subjects: [100], targets: nil, fabric_index: 1}
      ]})

      report = Router.handle_read(FabricDevice,
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
      GenServer.call(acl_name, {:write_attribute, :acl, [
        %{privilege: 5, auth_mode: 2, subjects: [100], targets: nil, fabric_index: 1},
        %{privilege: 5, auth_mode: 2, subjects: [200], targets: nil, fabric_index: 2}
      ]})

      # Write new ACL for fabric 1 via Router (which merges)
      context = %{auth_mode: :case, subject: 100, fabric_index: 1}
      new_entry = %{privilege: 3, auth_mode: 2, subjects: [100], targets: nil, fabric_index: 1}

      write_req = %IM.WriteRequest{
        write_requests: [%{
          path: %{endpoint: 0, cluster: 0x001F, attribute: 0},
          value: [new_entry]
        }]
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
  end
end
