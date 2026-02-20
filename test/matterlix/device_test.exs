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
      assert [%{device_type: 0x0100, revision: 1}] = device_types
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
      # OnOff has 6 attributes: on_off, cluster_revision + 4 global attrs
      req = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006}]
      }

      %IM.ReportData{attribute_reports: reports} = Router.handle_read(TestLight, req)
      data_reports = for {:data, d} <- reports, do: d
      assert length(data_reports) == 6

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
      # 1 from concrete + 6 from wildcard (on_off + cluster_revision + 4 global)
      assert length(data_reports) == 7
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
