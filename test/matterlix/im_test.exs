defmodule Matterlix.IMTest do
  use ExUnit.Case, async: true

  alias Matterlix.IM
  alias Matterlix.IM.Status

  # ── Status ────────────────────────────────────────────────────

  describe "Status.status_name/1" do
    test "known codes" do
      assert Status.status_name(0x00) == :success
      assert Status.status_name(0x01) == :failure
      assert Status.status_name(0x86) == :unsupported_attribute
      assert Status.status_name(0xC3) == :unsupported_cluster
      assert Status.status_name(0xC6) == :needs_timed_interaction
    end

    test "unknown code" do
      assert Status.status_name(0xFF) == {:unknown, 0xFF}
    end
  end

  describe "Status.status_code/1" do
    test "known names" do
      assert Status.status_code(:success) == 0x00
      assert Status.status_code(:failure) == 0x01
      assert Status.status_code(:unsupported_attribute) == 0x86
      assert Status.status_code(:constraint_error) == 0x87
    end

    test "unknown name raises" do
      assert_raise KeyError, fn -> Status.status_code(:bogus) end
    end
  end

  # ── StatusResponse ────────────────────────────────────────────

  describe "StatusResponse" do
    test "encode/decode roundtrip" do
      msg = %IM.StatusResponse{status: 0}
      {:ok, decoded} = IM.decode(:status_response, IM.encode(msg))
      assert decoded.status == 0
    end

    test "non-zero status" do
      msg = %IM.StatusResponse{status: 0x86}
      {:ok, decoded} = IM.decode(:status_response, IM.encode(msg))
      assert decoded.status == 0x86
    end
  end

  # ── TimedRequest ──────────────────────────────────────────────

  describe "TimedRequest" do
    test "encode/decode roundtrip" do
      msg = %IM.TimedRequest{timeout_ms: 5000}
      {:ok, decoded} = IM.decode(:timed_request, IM.encode(msg))
      assert decoded.timeout_ms == 5000
    end
  end

  # ── ReadRequest ───────────────────────────────────────────────

  describe "ReadRequest" do
    test "encode/decode with single path" do
      msg = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}],
        fabric_filtered: true
      }

      {:ok, decoded} = IM.decode(:read_request, IM.encode(msg))
      assert decoded.fabric_filtered == true
      assert [path] = decoded.attribute_paths
      assert path.endpoint == 1
      assert path.cluster == 0x0006
      assert path.attribute == 0x0000
    end

    test "encode/decode with multiple paths" do
      msg = %IM.ReadRequest{
        attribute_paths: [
          %{endpoint: 1, cluster: 0x0006, attribute: 0x0000},
          %{endpoint: 2, cluster: 0x0008, attribute: 0x0001}
        ],
        fabric_filtered: false
      }

      {:ok, decoded} = IM.decode(:read_request, IM.encode(msg))
      assert decoded.fabric_filtered == false
      assert length(decoded.attribute_paths) == 2
    end

    test "encode/decode with no paths" do
      msg = %IM.ReadRequest{attribute_paths: [], fabric_filtered: true}
      {:ok, decoded} = IM.decode(:read_request, IM.encode(msg))
      assert decoded.attribute_paths == []
      assert decoded.fabric_filtered == true
    end

    test "wildcard path (no endpoint)" do
      msg = %IM.ReadRequest{
        attribute_paths: [%{cluster: 0x0006, attribute: 0x0000}],
        fabric_filtered: true
      }

      {:ok, decoded} = IM.decode(:read_request, IM.encode(msg))
      [path] = decoded.attribute_paths
      refute Map.has_key?(path, :endpoint)
      assert path.cluster == 0x0006
    end

    test "encode/decode with data_version_filters" do
      msg = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}],
        data_version_filters: [
          %{endpoint: 1, cluster: 0x0006, data_version: 42}
        ],
        fabric_filtered: true
      }

      {:ok, decoded} = IM.decode(:read_request, IM.encode(msg))
      assert [filter] = decoded.data_version_filters
      assert filter.endpoint == 1
      assert filter.cluster == 0x0006
      assert filter.data_version == 42
    end

    test "encode/decode with empty data_version_filters" do
      msg = %IM.ReadRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}],
        data_version_filters: [],
        fabric_filtered: true
      }

      {:ok, decoded} = IM.decode(:read_request, IM.encode(msg))
      assert decoded.data_version_filters == []
    end
  end

  # ── ReportData ────────────────────────────────────────────────

  describe "ReportData" do
    test "encode/decode with data report" do
      msg = %IM.ReportData{
        subscription_id: 42,
        attribute_reports: [
          {:data, %{
            version: 1,
            path: %{endpoint: 1, cluster: 0x0006, attribute: 0x0000},
            value: {:bool, true}
          }}
        ]
      }

      {:ok, decoded} = IM.decode(:report_data, IM.encode(msg))
      assert decoded.subscription_id == 42
      assert [{:data, report}] = decoded.attribute_reports
      assert report.version == 1
      assert report.path.endpoint == 1
      assert report.value == true
    end

    test "encode/decode with status report" do
      msg = %IM.ReportData{
        attribute_reports: [
          {:status, %{
            path: %{endpoint: 1, cluster: 0x0006, attribute: 0x0000},
            status: 0x86,
            cluster_status: nil
          }}
        ]
      }

      {:ok, decoded} = IM.decode(:report_data, IM.encode(msg))
      assert [{:status, report}] = decoded.attribute_reports
      assert report.path.endpoint == 1
      assert report.status == 0x86
      assert report.cluster_status == nil
    end

    test "encode/decode with suppress_response" do
      msg = %IM.ReportData{suppress_response: true}
      {:ok, decoded} = IM.decode(:report_data, IM.encode(msg))
      assert decoded.suppress_response == true
    end

    test "encode/decode without subscription_id" do
      msg = %IM.ReportData{subscription_id: nil, attribute_reports: []}
      {:ok, decoded} = IM.decode(:report_data, IM.encode(msg))
      assert decoded.subscription_id == nil
    end

    test "multiple attribute reports" do
      msg = %IM.ReportData{
        attribute_reports: [
          {:data, %{
            version: 1,
            path: %{endpoint: 1, cluster: 0x0006, attribute: 0x0000},
            value: {:bool, true}
          }},
          {:data, %{
            version: 2,
            path: %{endpoint: 1, cluster: 0x0008, attribute: 0x0000},
            value: {:uint, 128}
          }}
        ]
      }

      {:ok, decoded} = IM.decode(:report_data, IM.encode(msg))
      assert length(decoded.attribute_reports) == 2

      [{:data, r1}, {:data, r2}] = decoded.attribute_reports
      assert r1.value == true
      assert r2.value == 128
    end
  end

  # ── WriteRequest ──────────────────────────────────────────────

  describe "WriteRequest" do
    test "encode/decode roundtrip" do
      msg = %IM.WriteRequest{
        write_requests: [
          %{
            version: 1,
            path: %{endpoint: 1, cluster: 0x0006, attribute: 0x0000},
            value: {:bool, false}
          }
        ],
        timed_request: false,
        suppress_response: false
      }

      {:ok, decoded} = IM.decode(:write_request, IM.encode(msg))
      assert decoded.timed_request == false
      assert decoded.suppress_response == false
      assert [write] = decoded.write_requests
      assert write.version == 1
      assert write.path.endpoint == 1
      assert write.value == false
    end

    test "timed write request" do
      msg = %IM.WriteRequest{
        write_requests: [],
        timed_request: true,
        suppress_response: true
      }

      {:ok, decoded} = IM.decode(:write_request, IM.encode(msg))
      assert decoded.timed_request == true
      assert decoded.suppress_response == true
    end
  end

  # ── WriteResponse ─────────────────────────────────────────────

  describe "WriteResponse" do
    test "encode/decode with success" do
      msg = %IM.WriteResponse{
        write_responses: [
          %{
            path: %{endpoint: 1, cluster: 0x0006, attribute: 0x0000},
            status: 0x00,
            cluster_status: nil
          }
        ]
      }

      {:ok, decoded} = IM.decode(:write_response, IM.encode(msg))
      assert [resp] = decoded.write_responses
      assert resp.path.endpoint == 1
      assert resp.status == 0x00
      assert resp.cluster_status == nil
    end

    test "encode/decode with error status" do
      msg = %IM.WriteResponse{
        write_responses: [
          %{
            path: %{endpoint: 1, cluster: 0x0006, attribute: 0x0000},
            status: 0x88,
            cluster_status: nil
          }
        ]
      }

      {:ok, decoded} = IM.decode(:write_response, IM.encode(msg))
      assert [resp] = decoded.write_responses
      assert resp.status == 0x88
    end
  end

  # ── InvokeRequest ─────────────────────────────────────────────

  describe "InvokeRequest" do
    test "encode/decode with command" do
      msg = %IM.InvokeRequest{
        invoke_requests: [
          %{
            path: %{endpoint: 1, cluster: 0x0006, command: 0x02},
            fields: %{0 => {:uint, 10}, 1 => {:uint, 0}}
          }
        ],
        timed_request: false,
        suppress_response: false
      }

      {:ok, decoded} = IM.decode(:invoke_request, IM.encode(msg))
      assert [invoke] = decoded.invoke_requests
      assert invoke.path.endpoint == 1
      assert invoke.path.cluster == 0x0006
      assert invoke.path.command == 0x02
      assert invoke.fields[0] == 10
      assert invoke.fields[1] == 0
    end

    test "command with no fields" do
      msg = %IM.InvokeRequest{
        invoke_requests: [
          %{path: %{endpoint: 1, cluster: 0x0006, command: 0x01}, fields: nil}
        ]
      }

      {:ok, decoded} = IM.decode(:invoke_request, IM.encode(msg))
      assert [invoke] = decoded.invoke_requests
      assert invoke.path.command == 0x01
      assert invoke.fields == nil
    end

    test "timed invoke request" do
      msg = %IM.InvokeRequest{
        invoke_requests: [],
        timed_request: true,
        suppress_response: false
      }

      {:ok, decoded} = IM.decode(:invoke_request, IM.encode(msg))
      assert decoded.timed_request == true
    end
  end

  # ── InvokeResponse ────────────────────────────────────────────

  describe "InvokeResponse" do
    test "encode/decode with command response" do
      msg = %IM.InvokeResponse{
        invoke_responses: [
          {:command, %{
            path: %{endpoint: 1, cluster: 0x0006, command: 0x02},
            fields: %{0 => {:uint, 0}}
          }}
        ]
      }

      {:ok, decoded} = IM.decode(:invoke_response, IM.encode(msg))
      assert [{:command, resp}] = decoded.invoke_responses
      assert resp.path.endpoint == 1
      assert resp.path.command == 0x02
      assert resp.fields[0] == 0
    end

    test "encode/decode with status response" do
      msg = %IM.InvokeResponse{
        invoke_responses: [
          {:status, %{
            path: %{endpoint: 1, cluster: 0x0006, command: 0x02},
            status: 0x00,
            cluster_status: nil
          }}
        ]
      }

      {:ok, decoded} = IM.decode(:invoke_response, IM.encode(msg))
      assert [{:status, resp}] = decoded.invoke_responses
      assert resp.path.command == 0x02
      assert resp.status == 0x00
      assert resp.cluster_status == nil
    end

    test "mixed command and status responses" do
      msg = %IM.InvokeResponse{
        invoke_responses: [
          {:command, %{
            path: %{endpoint: 1, cluster: 0x0006, command: 0x01},
            fields: nil
          }},
          {:status, %{
            path: %{endpoint: 1, cluster: 0x0006, command: 0x02},
            status: 0x81,
            cluster_status: nil
          }}
        ]
      }

      {:ok, decoded} = IM.decode(:invoke_response, IM.encode(msg))
      assert [{:command, _}, {:status, s}] = decoded.invoke_responses
      assert s.status == 0x81
    end
  end

  # ── SubscribeRequest ──────────────────────────────────────────

  describe "SubscribeRequest" do
    test "encode/decode roundtrip" do
      msg = %IM.SubscribeRequest{
        attribute_paths: [%{endpoint: 1, cluster: 0x0006, attribute: 0x0000}],
        min_interval: 0,
        max_interval: 60,
        fabric_filtered: true,
        keep_subscriptions: true
      }

      {:ok, decoded} = IM.decode(:subscribe_request, IM.encode(msg))
      assert decoded.min_interval == 0
      assert decoded.max_interval == 60
      assert decoded.fabric_filtered == true
      assert decoded.keep_subscriptions == true
      assert [path] = decoded.attribute_paths
      assert path.endpoint == 1
    end

    test "custom intervals" do
      msg = %IM.SubscribeRequest{
        attribute_paths: [],
        min_interval: 10,
        max_interval: 300,
        fabric_filtered: false,
        keep_subscriptions: false
      }

      {:ok, decoded} = IM.decode(:subscribe_request, IM.encode(msg))
      assert decoded.min_interval == 10
      assert decoded.max_interval == 300
      assert decoded.fabric_filtered == false
      assert decoded.keep_subscriptions == false
    end
  end

  # ── SubscribeResponse ─────────────────────────────────────────

  describe "SubscribeResponse" do
    test "encode/decode roundtrip" do
      msg = %IM.SubscribeResponse{subscription_id: 123, max_interval: 60}
      {:ok, decoded} = IM.decode(:subscribe_response, IM.encode(msg))
      assert decoded.subscription_id == 123
      assert decoded.max_interval == 60
    end
  end

  # ── Error handling ────────────────────────────────────────────

  describe "error handling" do
    test "unknown opcode" do
      binary = Matterlix.TLV.encode(%{0 => {:uint, 0}})
      assert {:error, :unknown_opcode} = IM.decode(:bogus_opcode, binary)
    end

    test "invalid TLV binary" do
      assert {:error, :invalid_tlv} = IM.decode(:status_response, <<0xFF, 0xFF>>)
    end
  end
end
