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

  # ── Full integration ──────────────────────────────────────────

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
