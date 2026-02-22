defmodule Matterlix.DeviceTest.TestLight do
  use Matterlix.Device,
    vendor_name: "TestCo",
    product_name: "TestLight",
    vendor_id: 0xFFF1,
    product_id: 0x8001

  endpoint 1, device_type: 0x0100 do
    cluster Matterlix.Cluster.OnOff
  end
end

defmodule Matterlix.DeviceTest do
  use ExUnit.Case

  alias Matterlix.DeviceTest.TestLight
  alias Matterlix.IM
  alias Matterlix.IM.Router
  alias Matterlix.IM.Status

  setup do
    start_supervised!(TestLight)
    :ok
  end

  # ── Device macro metadata ─────────────────────────────────────

  describe "device metadata" do
    test "endpoint 0 auto-generated" do
      assert MapSet.member?(TestLight.__endpoint_ids__(), 0)
    end

    test "endpoint 1 defined" do
      assert MapSet.member?(TestLight.__endpoint_ids__(), 1)
    end

    test "cluster module lookup" do
      assert TestLight.__cluster_module__(0, 0x001D) == Matterlix.Cluster.Descriptor
      assert TestLight.__cluster_module__(0, 0x0028) == Matterlix.Cluster.BasicInformation
      assert TestLight.__cluster_module__(1, 0x0006) == Matterlix.Cluster.OnOff
      assert TestLight.__cluster_module__(1, 0x9999) == nil
    end

    test "process name lookup" do
      assert TestLight.__process_name__(1, :on_off) ==
               :"Elixir.Matterlix.DeviceTest.TestLight.ep1.on_off"
    end
  end

  # ── Device convenience functions ──────────────────────────────

  describe "device convenience functions" do
    test "read_attribute" do
      assert {:ok, false} = TestLight.read_attribute(1, :on_off, :on_off)
    end

    test "write_attribute" do
      assert :ok = TestLight.write_attribute(1, :on_off, :on_off, true)
      assert {:ok, true} = TestLight.read_attribute(1, :on_off, :on_off)
    end

    test "invoke_command" do
      assert {:ok, nil} = TestLight.invoke_command(1, :on_off, :on, %{})
      assert {:ok, true} = TestLight.read_attribute(1, :on_off, :on_off)
    end

    test "read from unknown cluster" do
      assert {:error, :unsupported_cluster} =
               TestLight.read_attribute(1, :bogus_cluster, :something)
    end
  end

  # ── Endpoint 0 auto-population ────────────────────────────────

  describe "endpoint 0" do
    test "descriptor has server_list" do
      {:ok, server_list} = TestLight.read_attribute(0, :descriptor, :server_list)
      assert 0x001D in server_list
      assert 0x0028 in server_list
    end

    test "descriptor has parts_list" do
      {:ok, parts_list} = TestLight.read_attribute(0, :descriptor, :parts_list)
      assert parts_list == [1]
    end

    test "basic_information has vendor_name" do
      assert {:ok, "TestCo"} =
               TestLight.read_attribute(0, :basic_information, :vendor_name)
    end

    test "basic_information has product_name" do
      assert {:ok, "TestLight"} =
               TestLight.read_attribute(0, :basic_information, :product_name)
    end

    test "basic_information has vendor_id" do
      assert {:ok, 0xFFF1} =
               TestLight.read_attribute(0, :basic_information, :vendor_id)
    end
  end

  # ── Endpoint 1 descriptor ─────────────────────────────────────

  describe "endpoint 1 descriptor" do
    test "has server_list with OnOff and Descriptor" do
      {:ok, server_list} = TestLight.read_attribute(1, :descriptor, :server_list)
      assert 0x0006 in server_list
      assert 0x001D in server_list
    end

    test "has device_type_list" do
      {:ok, device_types} = TestLight.read_attribute(1, :descriptor, :device_type_list)
      assert [%{0 => {:uint, 0x0100}, 1 => {:uint, 1}}] = device_types  # DeviceTypeStruct: 0=type, 1=revision
    end
  end

  # ── Router: Read ──────────────────────────────────────────────

  describe "Router.handle_read/2" do
    test "reads attribute value" do
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      assert [{:data, data}] = reports
      assert data.path == %{endpoint: 1, cluster: 0x0006, attribute: 0x0000}
      assert data.value == {:bool, false}
    end

    test "reads multiple attributes" do
      req = %IM.ReadRequest{
        attribute_paths: [
          %{endpoint: 1, cluster: 0x0006, attribute: 0x0000},
          %{endpoint: 1, cluster: 0x0006, attribute: 0xFFFD}
        ]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      assert length(reports) == 2

      [{:data, on_off}, {:data, rev}] = reports
      assert on_off.value == {:bool, false}
      assert rev.value == {:uint, 4}
    end

    test "unsupported endpoint returns status" do
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 99, cluster: 0x0006, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      assert [{:status, status}] = reports
      assert status.status == Status.status_code(:unsupported_endpoint)
    end

    test "unsupported cluster returns status" do
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x9999, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      assert [{:status, status}] = reports
      assert status.status == Status.status_code(:unsupported_cluster)
    end

    test "unsupported attribute returns status" do
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x9999}]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      assert [{:status, status}] = reports
      assert status.status == Status.status_code(:unsupported_attribute)
    end
  end

  # ── Router: Write (via handle/3) ─────────────────────────────

  describe "Router write dispatch" do
    test "writes attribute successfully" do
      req = %IM.WriteRequest{
        write_requests: [
          %{
            version: 0,
            path: %{endpoint: 1, cluster: 0x0006, attribute: 0x0000},
            value: true
          }
        ]
      }

      %IM.WriteResponse{write_responses: responses} = Router.handle(TestLight, :write_request, req)
      assert [resp] = responses
      assert resp.status == Status.status_code(:success)

      assert {:ok, true} = TestLight.read_attribute(1, :on_off, :on_off)
    end

    test "write to read-only attribute fails" do
      req = %IM.WriteRequest{
        write_requests: [
          %{
            version: 0,
            path: %{endpoint: 1, cluster: 0x0006, attribute: 0xFFFD},
            value: 99
          }
        ]
      }

      %IM.WriteResponse{write_responses: responses} = Router.handle(TestLight, :write_request, req)
      assert [resp] = responses
      assert resp.status == Status.status_code(:unsupported_write)
    end

    test "write to unsupported endpoint fails" do
      req = %IM.WriteRequest{
        write_requests: [
          %{
            version: 0,
            path: %{endpoint: 99, cluster: 0x0006, attribute: 0x0000},
            value: true
          }
        ]
      }

      %IM.WriteResponse{write_responses: responses} = Router.handle(TestLight, :write_request, req)
      assert [resp] = responses
      assert resp.status == Status.status_code(:unsupported_endpoint)
    end
  end

  # ── Router: Invoke (via handle/3) ──────────────────────────────

  describe "Router invoke dispatch" do
    test "invoke on command" do
      req = %IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: 1, cluster: 0x0006, command: 0x01}, fields: nil}
        ]
      }

      %IM.InvokeResponse{invoke_responses: responses} = Router.handle(TestLight, :invoke_request, req)
      assert [{:status, resp}] = responses
      assert resp.status == Status.status_code(:success)

      assert {:ok, true} = TestLight.read_attribute(1, :on_off, :on_off)
    end

    test "invoke toggle command" do
      req = %IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: 1, cluster: 0x0006, command: 0x02}, fields: nil}
        ]
      }

      Router.handle(TestLight, :invoke_request, req)
      assert {:ok, true} = TestLight.read_attribute(1, :on_off, :on_off)

      Router.handle(TestLight, :invoke_request, req)
      assert {:ok, false} = TestLight.read_attribute(1, :on_off, :on_off)
    end

    test "invoke unsupported command" do
      req = %IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: 1, cluster: 0x0006, command: 0xFF}, fields: nil}
        ]
      }

      %IM.InvokeResponse{invoke_responses: responses} = Router.handle(TestLight, :invoke_request, req)
      assert [{:status, resp}] = responses
      assert resp.status == Status.status_code(:unsupported_command)
    end

    test "invoke on unsupported endpoint" do
      req = %IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: 99, cluster: 0x0006, command: 0x01}, fields: nil}
        ]
      }

      %IM.InvokeResponse{invoke_responses: responses} = Router.handle(TestLight, :invoke_request, req)
      assert [{:status, resp}] = responses
      assert resp.status == Status.status_code(:unsupported_endpoint)
    end
  end

  # ── Router: TimedRequest ─────────────────────────────────────

  describe "Router timed_request" do
    test "returns StatusResponse with success" do
      result = Router.handle(TestLight, :timed_request, %IM.TimedRequest{timeout_ms: 5000})
      assert %IM.StatusResponse{status: 0} = result
    end
  end

  # ── Device __cluster_ids__ ────────────────────────────────────

  describe "cluster_ids" do
    test "__cluster_ids__ returns cluster IDs for endpoint" do
      ids = TestLight.__cluster_ids__(1)
      assert 0x001D in ids  # Descriptor
      assert 0x0006 in ids  # OnOff
    end

    test "__cluster_ids__ returns empty for unknown endpoint" do
      assert TestLight.__cluster_ids__(99) == []
    end
  end

  # ── Wildcard reads ──────────────────────────────────────────

  describe "wildcard reads" do
    test "wildcard endpoint reads from all endpoints with matching cluster" do
      # OnOff (0x0006) is only on endpoint 1, so wildcard endpoint with cluster 0x0006
      # should return results from endpoint 1 only
      req = %IM.ReadRequest{
        attribute_paths: [%{cluster: 0x0006, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      data_reports = for {:data, d} <- reports, do: d
      assert length(data_reports) == 1
      assert hd(data_reports).path.endpoint == 1
    end

    test "wildcard cluster reads cluster_revision from all clusters on endpoint" do
      # Endpoint 1 has Descriptor + OnOff, both have cluster_revision (0xFFFD)
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, attribute: 0xFFFD}]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      data_reports = for {:data, d} <- reports, do: d
      assert length(data_reports) == 2

      clusters = Enum.map(data_reports, & &1.path.cluster) |> Enum.sort()
      assert 0x0006 in clusters  # OnOff
      assert 0x001D in clusters  # Descriptor
    end

    test "wildcard attribute reads all attributes from a cluster" do
      # OnOff has 7 attributes: on_off, cluster_revision + 5 global attrs
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006}]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      data_reports = for {:data, d} <- reports, do: d
      assert length(data_reports) == 7

      attr_ids = Enum.map(data_reports, & &1.path.attribute) |> Enum.sort()
      assert 0x0000 in attr_ids
      assert 0xFFFD in attr_ids
      assert 0xFFFB in attr_ids  # AttributeList
    end

    test "fully wildcard reads all attributes across all endpoints" do
      req = %IM.ReadRequest{attribute_paths: [%{}]}

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      data_reports = for {:data, d} <- reports, do: d

      # Should get attributes from ep0 (Descriptor, BasicInformation,
      # GeneralCommissioning, OperationalCredentials, AccessControl) and
      # ep1 (Descriptor, OnOff) — many attributes total
      assert length(data_reports) > 10

      endpoints = data_reports |> Enum.map(& &1.path.endpoint) |> Enum.uniq() |> Enum.sort()
      assert endpoints == [0, 1]
    end

    test "wildcard matching no cluster returns empty" do
      req = %IM.ReadRequest{
        attribute_paths: [%{cluster: 0x9999, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      # Wildcard (no endpoint key) that matches nothing → silently omitted
      assert reports == []
    end

    test "mixed wildcard and concrete paths" do
      req = %IM.ReadRequest{
        attribute_paths: [
          # Concrete path
          %{endpoint: 1, cluster: 0x0006, attribute: 0x0000},
          # Wildcard: all attributes on ep1 OnOff
          %{endpoint: 1, cluster: 0x0006}
        ]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      data_reports = for {:data, d} <- reports, do: d
      # 1 from concrete + 7 from wildcard (on_off + cluster_revision + 5 global)
      assert length(data_reports) == 8
    end

    test "concrete path error still returns status" do
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 99, cluster: 0x0006, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      assert [{:status, status}] = reports
      assert status.status == Status.status_code(:unsupported_endpoint)
    end
  end

  # ── DataVersion in reports ──────────────────────────────────

  describe "DataVersion in reports" do
    test "report includes data_version" do
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: [{:data, data}]} =
        Router.handle_read(TestLight, req)

      assert is_integer(data.version)
    end

    test "data_version increments after write" do
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: [{:data, data}]} =
        Router.handle_read(TestLight, req)

      v0 = data.version

      # Write to bump version
      write_req = %IM.WriteRequest{
        write_requests: [
          %{version: 0, path: %{endpoint: 1, cluster: 0x0006, attribute: 0x0000}, value: true}
        ]
      }

      Router.handle(TestLight, :write_request, write_req)

      %IM.ReportData{attribute_reports: [{:data, data}]} =
        Router.handle_read(TestLight, req)

      assert data.version == v0 + 1
    end
  end

  # ── DataVersionFilter ──────────────────────────────────────

  describe "DataVersionFilter" do
    test "matching filter skips cluster attributes" do
      # Read current version
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: [{:data, data}]} =
        Router.handle_read(TestLight, req)

      current_version = data.version

      # Read with matching DataVersionFilter → skipped
      filtered_req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}],
        data_version_filters: [
          %{endpoint: 1, cluster: 0x0006, data_version: current_version}
        ]
      }

      %IM.ReportData{attribute_reports: reports} =
        Router.handle_read(TestLight, filtered_req)

      assert reports == []
    end

    test "non-matching filter still returns data" do
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}],
        data_version_filters: [
          %{endpoint: 1, cluster: 0x0006, data_version: 999_999}
        ]
      }

      %IM.ReportData{attribute_reports: reports} =
        Router.handle_read(TestLight, req)

      assert [{:data, _}] = reports
    end

    test "filter for one cluster does not affect other clusters" do
      # Get OnOff version
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: [{:data, data}]} =
        Router.handle_read(TestLight, req)

      onoff_version = data.version

      # Wildcard read on ep1 with filter matching OnOff only
      wildcard_req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, attribute: 0xFFFD}],
        data_version_filters: [
          %{endpoint: 1, cluster: 0x0006, data_version: onoff_version}
        ]
      }

      %IM.ReportData{attribute_reports: reports} =
        Router.handle_read(TestLight, wildcard_req)

      # Should get Descriptor's cluster_revision but not OnOff's
      data_reports = for {:data, d} <- reports, do: d
      clusters = Enum.map(data_reports, & &1.path.cluster)
      assert 0x001D in clusters
      refute 0x0006 in clusters
    end

    test "filter after write with stale version returns data" do
      # Read initial version
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: [{:data, data}]} =
        Router.handle_read(TestLight, req)

      stale_version = data.version

      # Write to bump version
      write_req = %IM.WriteRequest{
        write_requests: [
          %{version: 0, path: %{endpoint: 1, cluster: 0x0006, attribute: 0x0000}, value: true}
        ]
      }

      Router.handle(TestLight, :write_request, write_req)

      # Use stale version in filter → should NOT skip (version changed)
      filtered_req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}],
        data_version_filters: [
          %{endpoint: 1, cluster: 0x0006, data_version: stale_version}
        ]
      }

      %IM.ReportData{attribute_reports: reports} =
        Router.handle_read(TestLight, filtered_req)

      assert [{:data, _}] = reports
    end
  end

  # ── Event reads through Router ───────────────────────────────

  describe "Event reads" do
    test "BasicInformation StartUp event is emitted on device start" do
      req = %IM.ReadRequest{
        event_requests: [%{endpoint: 0, cluster: 0x0028, event: 0x00}]
      }

      %IM.ReportData{event_reports: events} = Router.handle_read(TestLight, req)
      assert length(events) >= 1

      {:data, event} = hd(events)
      assert event.path.endpoint == 0
      assert event.path.cluster == 0x0028
      assert event.path.event == 0x00
      assert event.priority == 2
      assert event.data == %{0 => {:uint, 1}}
    end

    test "event_min filter skips old events" do
      # Read all events first to get the latest number
      req = %IM.ReadRequest{
        event_requests: [%{endpoint: 0, cluster: 0x0028}]
      }

      %IM.ReportData{event_reports: events} = Router.handle_read(TestLight, req)
      assert length(events) >= 1

      # Use event_min beyond all known events
      {:data, last} = List.last(events)
      future_min = last.event_number + 1

      filtered_req = %IM.ReadRequest{
        event_requests: [%{endpoint: 0, cluster: 0x0028}],
        event_filters: [%{event_min: future_min}]
      }

      %IM.ReportData{event_reports: filtered_events} = Router.handle_read(TestLight, filtered_req)
      assert filtered_events == []
    end

    test "no event_requests returns empty event_reports" do
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}]
      }

      %IM.ReportData{event_reports: events} = Router.handle_read(TestLight, req)
      assert events == []
    end

    test "mixed attribute and event read" do
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}],
        event_requests: [%{endpoint: 0, cluster: 0x0028, event: 0x00}]
      }

      %IM.ReportData{attribute_reports: attrs, event_reports: events} =
        Router.handle_read(TestLight, req)

      assert length(attrs) == 1
      assert length(events) >= 1
    end
  end

  # ── Full integration ────────────────────────────────────────

  describe "full integration" do
    test "read → write → invoke → read" do
      # Read initial state
      read_req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}]
      }

      %IM.ReportData{attribute_reports: [{:data, data}]} =
        Router.handle_read(TestLight, read_req)

      assert data.value == {:bool, false}

      # Write on_off to true
      write_req = %IM.WriteRequest{
        write_requests: [
          %{
            version: 0,
            path: %{endpoint: 1, cluster: 0x0006, attribute: 0x0000},
            value: true
          }
        ]
      }

      %IM.WriteResponse{write_responses: [resp]} = Router.handle(TestLight, :write_request, write_req)
      assert resp.status == Status.status_code(:success)

      # Read to confirm write
      %IM.ReportData{attribute_reports: [{:data, data}]} =
        Router.handle_read(TestLight, read_req)

      assert data.value == {:bool, true}

      # Invoke toggle
      invoke_req = %IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: 1, cluster: 0x0006, command: 0x02}, fields: nil}
        ]
      }

      Router.handle(TestLight, :invoke_request, invoke_req)

      # Read to confirm toggle
      %IM.ReportData{attribute_reports: [{:data, data}]} =
        Router.handle_read(TestLight, read_req)

      assert data.value == {:bool, false}
    end
  end
end
