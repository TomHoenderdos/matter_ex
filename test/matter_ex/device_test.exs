defmodule MatterEx.DeviceTest.TestLight do
  use MatterEx.Device,
    vendor_name: "TestCo",
    product_name: "TestLight",
    vendor_id: 0xFFF1,
    product_id: 0x8001

  endpoint 1, device_type: 0x0100 do
    cluster(MatterEx.Cluster.OnOff)
  end
end

defmodule MatterEx.DeviceTest.TestSensor do
  use MatterEx.Device,
    vendor_name: "TestCo",
    product_name: "TestSensor",
    vendor_id: 0xFFF1,
    product_id: 0x8002

  endpoint 1, device_type: 0x0302 do
    cluster(MatterEx.Cluster.Identify)
    cluster(MatterEx.Cluster.TemperatureMeasurement)
  end
end

defmodule MatterEx.DeviceTest.FriendlyDevice do
  use MatterEx.Device,
    vendor_name: "TestCo",
    product_name: "FriendlyDevice",
    vendor_id: 0xFFF1,
    product_id: 0x8003

  endpoint :light, :on_off_light do
    cluster(:on_off)
  end

  endpoint :sensor, :temperature_sensor do
    cluster(:identify)
    cluster(:temperature_measurement)
  end
end

defmodule MatterEx.DeviceTest.PresetDevice do
  use MatterEx.Device,
    vendor: :test,
    product: :smart_light

  endpoint(:light, :dimmable_light)
end

defmodule MatterEx.DeviceTest do
  use ExUnit.Case

  alias MatterEx.DeviceTest.FriendlyDevice
  alias MatterEx.DeviceTest.PresetDevice
  alias MatterEx.DeviceTest.TestLight
  alias MatterEx.DeviceTest.TestSensor
  alias MatterEx.IM
  alias MatterEx.IM.Router
  alias MatterEx.IM.Status

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
      assert TestLight.__cluster_module__(0, 0x001D) == MatterEx.Cluster.Descriptor
      assert TestLight.__cluster_module__(0, 0x0028) == MatterEx.Cluster.BasicInformation
      assert TestLight.__cluster_module__(1, 0x0006) == MatterEx.Cluster.OnOff
      assert TestLight.__cluster_module__(1, 0x9999) == nil
    end

    test "process name lookup" do
      assert TestLight.__process_name__(1, :on_off) ==
               :"Elixir.MatterEx.DeviceTest.TestLight.ep1.on_off"
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

  describe "friendly device DSL" do
    setup do
      start_supervised!(FriendlyDevice)
      :ok
    end

    test "endpoint aliases resolve to generated endpoint IDs" do
      assert FriendlyDevice.endpoints() == %{root: 0, light: 1, sensor: 2}
      assert FriendlyDevice.__endpoint_id__(:light) == 1
      assert FriendlyDevice.__endpoint_id__(:sensor) == 2
      assert FriendlyDevice.__endpoint_id__(:missing) == nil
    end

    test "named device types populate descriptor device_type_list" do
      assert {:ok, [%{0 => {:uint, 0x0100}, 1 => {:uint, 3}}]} =
               FriendlyDevice.read_attribute(:light, :descriptor, :device_type_list)

      assert {:ok, [%{0 => {:uint, 0x0302}, 1 => {:uint, 2}}]} =
               FriendlyDevice.read_attribute(:sensor, :descriptor, :device_type_list)
    end

    test "cluster aliases produce the same server lists as module declarations" do
      assert 0x0006 in FriendlyDevice.__cluster_ids__(:light)
      assert 0x0402 in FriendlyDevice.__cluster_ids__(:sensor)
      assert FriendlyDevice.__cluster_module__(:light, 0x0006) == MatterEx.Cluster.OnOff
    end

    test "lists clusters by endpoint alias" do
      assert :on_off in FriendlyDevice.clusters(:light)
      assert :temperature_measurement in FriendlyDevice.clusters(:sensor)
      assert {:error, :unsupported_endpoint} = FriendlyDevice.clusters(:missing)
    end

    test "explicit runtime calls accept endpoint aliases" do
      assert {:ok, false} = FriendlyDevice.read_attribute(:light, :on_off, :on_off)
      assert :ok = FriendlyDevice.write_attribute(:light, :on_off, :on_off, true)
      assert {:ok, true} = FriendlyDevice.read_attribute(:light, :on_off, :on_off)
      assert {:ok, nil} = FriendlyDevice.invoke_command(:light, :on_off, :toggle)
      assert {:ok, false} = FriendlyDevice.read_attribute(:light, :on_off, :on_off)
    end

    test "shortcut attribute calls resolve unambiguous attributes" do
      assert {:ok, false} = FriendlyDevice.read_attribute(:light, :on_off)
      assert :ok = FriendlyDevice.update_attribute(:light, :on_off, true)
      assert {:ok, true} = FriendlyDevice.read_attribute(:light, :on_off)
    end

    test "shortcut attribute calls report ambiguous attributes" do
      assert {:error, :ambiguous_attribute} =
               FriendlyDevice.read_attribute(:light, :cluster_revision)
    end

    test "shortcut command calls resolve unambiguous commands" do
      assert {:ok, nil} = FriendlyDevice.invoke(:light, :on)
      assert {:ok, true} = FriendlyDevice.read_attribute(:light, :on_off)
    end

    test "unknown endpoint returns unsupported_endpoint" do
      assert {:error, :unsupported_endpoint} =
               FriendlyDevice.read_attribute(:missing, :on_off, :on_off)
    end
  end

  describe "device presets" do
    setup do
      start_supervised!(PresetDevice)
      :ok
    end

    test "known vendor and product aliases are discoverable" do
      assert {:test, vendor_opts} = List.keyfind(MatterEx.Device.known_vendors(), :test, 0)
      assert vendor_opts[:vendor_name] == "MatterEx Test"
      assert vendor_opts[:vendor_id] == 0xFFF1

      assert {:smart_light, product_opts} =
               List.keyfind(MatterEx.Device.known_products(), :smart_light, 0)

      assert product_opts[:product_name] == "Smart Light"
      assert product_opts[:product_id] == 0x8001
    end

    test "known aliases resolve to numeric vendor and product IDs" do
      assert MatterEx.Device.vendor_id!(:test) == 0xFFF1
      assert MatterEx.Device.product_id!(:matter_example) == 0x8000
      assert MatterEx.Device.product_id!(:net_test) == 0x8000
      assert MatterEx.Device.vendor_id!(0xFFF1) == 0xFFF1
      assert MatterEx.Device.product_id!(0x8000) == 0x8000
    end

    test "vendor and product aliases populate BasicInformation" do
      assert {:ok, "MatterEx Test"} =
               PresetDevice.read_attribute(:root, :basic_information, :vendor_name)

      assert {:ok, 0xFFF1} =
               PresetDevice.read_attribute(:root, :basic_information, :vendor_id)

      assert {:ok, "Smart Light"} =
               PresetDevice.read_attribute(:root, :basic_information, :product_name)

      assert {:ok, 0x8001} =
               PresetDevice.read_attribute(:root, :basic_information, :product_id)
    end

    test "named endpoint without a block auto-composes required clusters" do
      assert PresetDevice.endpoints() == %{root: 0, light: 1}

      assert PresetDevice.__cluster_ids__(:light) |> Enum.sort() == [
               0x0003,
               0x0004,
               0x0005,
               0x0006,
               0x0008,
               0x001D
             ]

      assert :identify in PresetDevice.clusters(:light)
      assert :level_control in PresetDevice.clusters(:light)
      assert :on_off in PresetDevice.clusters(:light)
    end

    test "auto-composed endpoint works with shortcut calls" do
      assert {:ok, false} = PresetDevice.read_attribute(:light, :on_off)
      assert {:ok, nil} = PresetDevice.invoke(:light, :on)
      assert {:ok, true} = PresetDevice.read_attribute(:light, :on_off)
    end
  end

  describe "internal sensor updates" do
    setup do
      start_supervised!(TestSensor)
      :ok
    end

    test "update_attribute changes read-only sensor values" do
      assert {:ok, 2000} =
               TestSensor.read_attribute(1, :temperature_measurement, :measured_value)

      assert :ok =
               TestSensor.update_attribute(1, :temperature_measurement, :measured_value, 2150)

      assert {:ok, 2150} =
               TestSensor.read_attribute(1, :temperature_measurement, :measured_value)
    end

    test "write_attribute still rejects controller writes to read-only sensor values" do
      assert {:error, :unsupported_write} =
               TestSensor.write_attribute(1, :temperature_measurement, :measured_value, 2200)
    end
  end

  # ── Endpoint 0 auto-population ────────────────────────────────

  describe "endpoint 0" do
    test "descriptor has server_list" do
      {:ok, server_list} = TestLight.read_attribute(0, :descriptor, :server_list)
      assert 0x001D in server_list
      assert 0x0028 in server_list
      assert 0x001F in server_list
      assert 0x0030 in server_list
      assert 0x0031 in server_list
      assert 0x0033 in server_list
      assert 0x0038 in server_list
      assert 0x0046 in server_list
      assert 0x1349FC00 in server_list
      assert 0x003C in server_list
      assert 0x003E in server_list
      assert 0x003F in server_list
    end

    test "descriptor has parts_list" do
      {:ok, parts_list} = TestLight.read_attribute(0, :descriptor, :parts_list)
      assert parts_list == [1]
    end

    test "basic_information has vendor_name" do
      assert {:ok, "TestCo"} =
               TestLight.read_attribute(0, :basic_information, :vendor_name)
    end

    test "apple private cluster has observed commissioning attribute" do
      assert {:ok, true} =
               TestLight.read_attribute(0, :apple_private, :unknown_attribute_1)
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
      # DeviceTypeStruct: 0=type, 1=revision
      assert [%{0 => {:uint, 0x0100}, 1 => {:uint, 3}}] = device_types
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
      assert rev.value == {:uint16, 4}
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

      %IM.WriteResponse{write_responses: responses} =
        Router.handle(TestLight, :write_request, req)

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

      %IM.WriteResponse{write_responses: responses} =
        Router.handle(TestLight, :write_request, req)

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

      %IM.WriteResponse{write_responses: responses} =
        Router.handle(TestLight, :write_request, req)

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

      %IM.InvokeResponse{invoke_responses: responses} =
        Router.handle(TestLight, :invoke_request, req)

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

      %IM.InvokeResponse{invoke_responses: responses} =
        Router.handle(TestLight, :invoke_request, req)

      assert [{:status, resp}] = responses
      assert resp.status == Status.status_code(:unsupported_command)
    end

    test "invoke on unsupported endpoint" do
      req = %IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: 99, cluster: 0x0006, command: 0x01}, fields: nil}
        ]
      }

      %IM.InvokeResponse{invoke_responses: responses} =
        Router.handle(TestLight, :invoke_request, req)

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
      # Descriptor
      assert 0x001D in ids
      # OnOff
      assert 0x0006 in ids
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
      # OnOff
      assert 0x0006 in clusters
      # Descriptor
      assert 0x001D in clusters
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
      # AttributeList
      assert 0xFFFB in attr_ids
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
      assert events != []

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
      assert events != []

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
      assert events != []
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

      %IM.WriteResponse{write_responses: [resp]} =
        Router.handle(TestLight, :write_request, write_req)

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
