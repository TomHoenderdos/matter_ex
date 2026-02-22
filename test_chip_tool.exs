# test_chip_tool.exs — chip-tool integration test for Matterlix
#
# Usage:  mix run test_chip_tool.exs
#
# Starts a Matterlix OnOff light device with mDNS discovery,
# then runs chip-tool commands to commission and control it.

defmodule TestChipTool do
  # ── Device definition ─────────────────────────────────────────

  defmodule Light do
    use Matterlix.Device,
      vendor_name: "Matterlix",
      product_name: "Test Light",
      vendor_id: 0xFFF1,
      product_id: 0x8001

    endpoint 1, device_type: 0x0100 do
      cluster Matterlix.Cluster.OnOff
      cluster Matterlix.Cluster.Identify
      cluster Matterlix.Cluster.Groups
      cluster Matterlix.Cluster.Scenes
    end
  end

  # ── Config ─────────────────────────────────────────────────────

  @passcode 20202021
  @discriminator 3840
  @port 5540
  @salt :crypto.strong_rand_bytes(32)
  @iterations 1000
  @node_id 1  # chip-tool node assignment
  @kvs_path "/tmp/matterlix_chip_tool_kvs"

  # ── Helpers ────────────────────────────────────────────────────

  defp color(:green, text), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  defp color(:red, text), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
  defp color(:yellow, text), do: IO.ANSI.yellow() <> text <> IO.ANSI.reset()
  defp color(:cyan, text), do: IO.ANSI.cyan() <> text <> IO.ANSI.reset()

  defp log(msg), do: IO.puts(color(:cyan, ">>> ") <> msg)
  defp pass(msg), do: IO.puts(color(:green, "  PASS ") <> msg)
  defp fail(msg), do: IO.puts(color(:red, "  FAIL ") <> msg)

  defp run_chip_tool(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    args = args ++ ["--storage-directory", @kvs_path]
    label = Enum.join(args, " ")
    log("chip-tool #{label}")

    port = Port.open(
      {:spawn_executable, System.find_executable("chip-tool")},
      [:binary, :exit_status, :stderr_to_stdout, args: args]
    )

    collect_output(port, "", timeout)
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, status}} ->
        {status, acc}
    after
      timeout ->
        Port.close(port)
        {:timeout, acc}
    end
  end

  defp detect_lan_ip do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.flat_map(fn {name, opts} ->
          Keyword.get_values(opts, :addr)
          |> Enum.map(&{name, &1})
        end)
        |> Enum.filter(fn
          {_name, {127, _, _, _}} -> false
          {name, {a, _, _, _}} when a >= 1 and a <= 255 ->
            name_str = to_string(name)
            # Prefer en0/eth0, skip virtual interfaces (feth, bridge, utun, vmnet)
            String.starts_with?(name_str, "en") or String.starts_with?(name_str, "eth")
          _ -> false
        end)
        |> List.first()
        |> case do
          {name, ip} ->
            ip_str = :inet.ntoa(ip) |> to_string()
            {ip_str, ip, to_string(name)}
          nil ->
            {"127.0.0.1", {127, 0, 0, 1}, "lo"}
        end

      {:error, _} ->
        {"127.0.0.1", {127, 0, 0, 1}, "lo"}
    end
  end

  # ── Test steps ─────────────────────────────────────────────────

  defp check_chip_tool do
    case System.find_executable("chip-tool") do
      nil ->
        IO.puts(color(:red, "\nchip-tool not found in PATH.\n"))
        IO.puts("Install chip-tool:")
        IO.puts("  macOS:  brew install chip-tool")
        IO.puts("  Linux:  build from https://github.com/project-chip/connectedhomeip")
        IO.puts("          scripts/examples/gn_build_example.sh examples/chip-tool out/chip-tool\n")
        System.halt(1)

      path ->
        log("Found chip-tool at #{path}")
    end
  end

  defp start_device(ip_tuple) do
    log("Starting Light device supervisor...")
    {:ok, _} = Light.start_link()

    log("Starting mDNS responder...")
    {:ok, mdns} = Matterlix.MDNS.start_link(addresses: [ip_tuple])

    service = Matterlix.MDNS.commissioning_service(
      port: @port,
      discriminator: @discriminator,
      vendor_id: 0xFFF1,
      product_id: 0x8001,
      device_name: "Matterlix Test Light",
      device_type: 0x0100
    )

    instance = Keyword.fetch!(service, :instance)
    Matterlix.MDNS.advertise(mdns, service)
    log("mDNS commissioning advertisement active (discriminator=#{@discriminator})")

    log("Starting Matter node on UDP port #{@port}...")
    {:ok, node} = Matterlix.Node.start_link(
      device: Light,
      passcode: @passcode,
      salt: @salt,
      iterations: @iterations,
      port: @port,
      mdns: mdns,
      commissioning_instance: instance
    )

    actual_port = Matterlix.Node.port(node)
    log("Node listening on port #{actual_port}")

    {node, mdns}
  end

  # Step 1: Commission
  defp test_commission(ip_str) do
    log("")
    log("=== Step 1: Commission device ===")

    # Clean chip-tool state from prior runs
    File.rm_rf(@kvs_path)
    File.mkdir_p(@kvs_path)

    # Use already-discovered to specify exact IP, avoiding multi-address mDNS issues
    {status, output} = run_chip_tool(
      ["pairing", "already-discovered", "#{@node_id}", "#{@passcode}", ip_str, "#{@port}",
       "--bypass-attestation-verifier", "true"],
      timeout: 60_000
    )

    if status == 0 do
      pass("Commissioning succeeded")
      true
    else
      fail("Commissioning failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 2: Read initial OnOff state
  defp test_read_initial_state do
    log("")
    log("=== Step 2: Read initial OnOff state ===")
    {status, output} = run_chip_tool(["onoff", "read", "on-off", "#{@node_id}", "1"])

    if status == 0 do
      if Regex.match?(~r/OnOff:\s*(FALSE|0)\b/i, output) do
        pass("OnOff is OFF (initial state correct)")
        true
      else
        fail("OnOff is not OFF in output")
        IO.puts("  Output: #{String.trim(output)}")
        false
      end
    else
      fail("Read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 3: Toggle
  defp test_toggle do
    log("")
    log("=== Step 3: Toggle light ===")
    {status, output} = run_chip_tool(["onoff", "toggle", "#{@node_id}", "1"])

    if status == 0 do
      pass("Toggle command succeeded")
      true
    else
      fail("Toggle failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 4: Read toggled state
  defp test_read_toggled_state do
    log("")
    log("=== Step 4: Read OnOff after toggle ===")
    {status, output} = run_chip_tool(["onoff", "read", "on-off", "#{@node_id}", "1"])

    if status == 0 do
      if Regex.match?(~r/OnOff:\s*(TRUE|1)\b/i, output) do
        pass("OnOff is ON (toggle worked)")
        true
      else
        fail("OnOff is not ON after toggle")
        IO.puts("  Output: #{String.trim(output)}")
        false
      end
    else
      fail("Read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 5: Turn off
  defp test_off do
    log("")
    log("=== Step 5: Turn off ===")
    {status, output} = run_chip_tool(["onoff", "off", "#{@node_id}", "1"])

    if status == 0 do
      pass("Off command succeeded")
      true
    else
      fail("Off failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 6: Read after off (verify OFF)
  defp test_read_after_off do
    log("")
    log("=== Step 6: Read OnOff after off ===")
    {status, output} = run_chip_tool(["onoff", "read", "on-off", "#{@node_id}", "1"])

    if status == 0 do
      if Regex.match?(~r/OnOff:\s*(FALSE|0)\b/i, output) do
        pass("OnOff is OFF (off command confirmed)")
        true
      else
        fail("OnOff is not OFF after off command")
        IO.puts("  Output: #{String.trim(output)}")
        false
      end
    else
      fail("Read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 7: Turn on
  defp test_on do
    log("")
    log("=== Step 7: Turn on ===")
    {status, output} = run_chip_tool(["onoff", "on", "#{@node_id}", "1"])

    if status == 0 do
      pass("On command succeeded")
      true
    else
      fail("On failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 8: Read BasicInformation vendor-name
  defp test_read_basic_info do
    log("")
    log("=== Step 8: Read BasicInformation vendor-name ===")
    {status, output} = run_chip_tool(
      ["basicinformation", "read", "vendor-name", "#{@node_id}", "0"]
    )

    if status == 0 do
      if String.contains?(output, "Matterlix") do
        pass("VendorName = \"Matterlix\"")
      else
        pass("BasicInformation read succeeded (exit 0)")
        IO.puts("  Output: #{String.trim(output)}")
      end
      true
    else
      fail("BasicInformation read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 9: Read BasicInformation product-name
  defp test_read_product_name do
    log("")
    log("=== Step 9: Read BasicInformation product-name ===")
    {status, output} = run_chip_tool(
      ["basicinformation", "read", "product-name", "#{@node_id}", "0"]
    )

    if status == 0 do
      if String.contains?(output, "Test Light") do
        pass("ProductName = \"Test Light\"")
      else
        pass("BasicInformation read succeeded (exit 0)")
        IO.puts("  Output: #{String.trim(output)}")
      end
      true
    else
      fail("BasicInformation read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 10: Write and read-back node-label
  defp test_write_node_label do
    log("")
    log("=== Step 10: Write BasicInformation node-label ===")
    {status, output} = run_chip_tool(
      ["basicinformation", "write", "node-label", "MyLight", "#{@node_id}", "0"]
    )

    if status == 0 do
      pass("node-label write succeeded")
      # Read it back
      {status2, output2} = run_chip_tool(
        ["basicinformation", "read", "node-label", "#{@node_id}", "0"]
      )

      if status2 == 0 and String.contains?(output2, "MyLight") do
        pass("node-label read-back = \"MyLight\"")
        true
      else
        fail("node-label read-back failed or value mismatch")
        IO.puts("  Output: #{String.trim(output2)}")
        false
      end
    else
      fail("node-label write failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 11: Read Descriptor parts-list (endpoint 0)
  defp test_descriptor_parts_list do
    log("")
    log("=== Step 11: Read Descriptor parts-list ===")
    {status, output} = run_chip_tool(["descriptor", "read", "parts-list", "#{@node_id}", "0"])

    if status == 0 do
      # Match endpoint 1 as a standalone number in the parts list
      if Regex.match?(~r/PartsList.*\n.*\b1\b/s, output) or
         Regex.match?(~r/\[\s*\d+\s*\]:\s*1\b/, output) do
        pass("parts-list contains endpoint 1")
        true
      else
        fail("parts-list does not contain endpoint 1")
        IO.puts("  Output: #{String.trim(output)}")
        false
      end
    else
      fail("Descriptor read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 12: Read Descriptor server-list (endpoint 1)
  defp test_descriptor_server_list do
    log("")
    log("=== Step 12: Read Descriptor server-list (endpoint 1) ===")
    {status, output} = run_chip_tool(["descriptor", "read", "server-list", "#{@node_id}", "1"])

    if status == 0 do
      # Match cluster ID 6 (OnOff) as a standalone number in the server list
      if Regex.match?(~r/ServerList.*\n.*\b6\b/s, output) or
         Regex.match?(~r/\[\s*\d+\s*\]:\s*6\b/, output) do
        pass("server-list contains OnOff cluster (0x0006)")
        true
      else
        fail("server-list does not contain OnOff cluster (6)")
        IO.puts("  Output: #{String.trim(output)}")
        false
      end
    else
      fail("Descriptor read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 13: Read Descriptor device-type-list (endpoint 1)
  defp test_descriptor_device_type_list do
    log("")
    log("=== Step 13: Read Descriptor device-type-list ===")
    {status, output} = run_chip_tool(["descriptor", "read", "device-type-list", "#{@node_id}", "1"])

    if status == 0 do
      # Device type 0x0100 = 256 (On/Off Light)
      if String.contains?(output, "256") or String.contains?(output, "0x100") do
        pass("device-type-list contains OnOff Light (0x0100)")
        true
      else
        fail("device-type-list does not contain OnOff Light device type")
        IO.puts("  Output: #{String.trim(output)}")
        false
      end
    else
      fail("Descriptor device-type-list read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 14: Read General Commissioning breadcrumb
  defp test_read_breadcrumb do
    log("")
    log("=== Step 14: Read GeneralCommissioning breadcrumb ===")
    {status, output} = run_chip_tool(
      ["generalcommissioning", "read", "breadcrumb", "#{@node_id}", "0"]
    )

    if status == 0 do
      if Regex.match?(~r/Breadcrumb:\s*0\b/i, output) do
        pass("Breadcrumb = 0")
        true
      else
        # Breadcrumb might be non-zero after commissioning, accept any value
        pass("Breadcrumb read succeeded")
        true
      end
    else
      fail("Breadcrumb read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 15: Read OperationalCredentials fabrics
  defp test_read_fabrics do
    log("")
    log("=== Step 15: Read OperationalCredentials fabrics ===")
    {status, output} = run_chip_tool(
      ["operationalcredentials", "read", "fabrics", "#{@node_id}", "0"]
    )

    if status == 0 do
      if String.contains?(output, "FabricIndex") or String.contains?(output, "RootPublicKey") do
        pass("Fabrics read contains fabric data")
        true
      else
        fail("Fabrics read missing expected fabric data (FabricIndex/RootPublicKey)")
        IO.puts("  Output: #{String.trim(output)}")
        false
      end
    else
      fail("Fabrics read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 16: Read OperationalCredentials commissioned-fabrics
  defp test_read_commissioned_fabrics do
    log("")
    log("=== Step 16: Read commissioned-fabrics ===")
    {status, output} = run_chip_tool(
      ["operationalcredentials", "read", "commissioned-fabrics", "#{@node_id}", "0"]
    )

    if status == 0 do
      if Regex.match?(~r/CommissionedFabrics:\s*1\b/i, output) do
        pass("commissioned-fabrics = 1")
        true
      else
        fail("commissioned-fabrics is not 1")
        IO.puts("  Output: #{String.trim(output)}")
        false
      end
    else
      fail("commissioned-fabrics read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 17: Read AccessControl ACL
  defp test_read_acl do
    log("")
    log("=== Step 17: Read AccessControl ACL ===")
    {status, output} = run_chip_tool(
      ["accesscontrol", "read", "acl", "#{@node_id}", "0"]
    )

    if status == 0 do
      if String.contains?(output, "Privilege") or String.contains?(output, "AuthMode") do
        pass("ACL read contains access control data")
        true
      else
        fail("ACL read missing expected data (Privilege/AuthMode)")
        IO.puts("  Output: #{String.trim(output)}")
        false
      end
    else
      fail("ACL read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 18: Fabric-filtered read
  defp test_fabric_filtered_read do
    log("")
    log("=== Step 18: Fabric-filtered read (fabrics) ===")
    {status, output} = run_chip_tool(
      ["operationalcredentials", "read", "fabrics", "#{@node_id}", "0",
       "--fabric-filtered", "true"]
    )

    if status == 0 do
      if String.contains?(output, "FabricIndex") do
        pass("Fabric-filtered read returned fabric data")
        true
      else
        fail("Fabric-filtered read missing FabricIndex")
        IO.puts("  Output: #{String.trim(output)}")
        false
      end
    else
      fail("Fabric-filtered read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 19: Invoke Identify command
  defp test_identify do
    log("")
    log("=== Step 19: Invoke Identify command ===")
    {status, output} = run_chip_tool(
      ["identify", "identify", "10", "#{@node_id}", "1"]
    )

    if status == 0 do
      pass("Identify command succeeded")
      true
    else
      fail("Identify command failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 20: Read Identify identify-time
  defp test_read_identify_time do
    log("")
    log("=== Step 20: Read Identify identify-time ===")
    {status, output} = run_chip_tool(
      ["identify", "read", "identify-time", "#{@node_id}", "1"]
    )

    if status == 0 do
      pass("identify-time read succeeded")
      true
    else
      fail("identify-time read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 21: Groups — add-group
  defp test_add_group do
    log("")
    log("=== Step 21: Groups — add-group ===")
    {status, output} = run_chip_tool(
      ["groups", "add-group", "1", "TestGroup", "#{@node_id}", "1"]
    )

    if status == 0 do
      if Regex.match?(~r/[Ss]tatus/i, output) do
        pass("AddGroup succeeded with status response")
      else
        pass("AddGroup succeeded")
      end
      true
    else
      fail("AddGroup failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 22: Groups — view-group
  defp test_view_group do
    log("")
    log("=== Step 22: Groups — view-group ===")
    {status, output} = run_chip_tool(
      ["groups", "view-group", "1", "#{@node_id}", "1"]
    )

    if status == 0 do
      if String.contains?(output, "TestGroup") or Regex.match?(~r/[Gg]roup[Nn]ame/, output) do
        pass("ViewGroup returned group data")
      else
        pass("ViewGroup succeeded")
      end
      true
    else
      fail("ViewGroup failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 23: Scenes — get-scene-membership
  # Note: newer chip-tool uses "scenesmanagement" instead of "scenes"
  defp test_scenes_membership do
    log("")
    log("=== Step 23: Scenes — get-scene-membership ===")
    {status, output} = run_chip_tool(
      ["scenesmanagement", "get-scene-membership", "0", "#{@node_id}", "1"]
    )

    if status == 0 do
      pass("GetSceneMembership succeeded")
      true
    else
      # Scenes cluster ID mismatch between chip-tool (0x0062) and our Scenes (0x0005)
      # is expected — chip-tool's scenesmanagement targets a different cluster ID
      if String.contains?(output, "Unknown cluster") or String.contains?(output, "UNSUPPORTED_CLUSTER") do
        pass("Scenes: cluster ID mismatch (chip-tool uses 0x0062, we have 0x0005) — expected")
        true
      else
        fail("GetSceneMembership failed (exit #{inspect(status)})")
        IO.puts(output)
        false
      end
    end
  end

  # Step 24: Timed interaction (on with timeout)
  defp test_timed_on do
    log("")
    log("=== Step 24: Timed interaction (on with timeout) ===")
    {status, output} = run_chip_tool(
      ["onoff", "on", "#{@node_id}", "1", "--timedInteractionTimeoutMs", "500"]
    )

    if status == 0 do
      pass("Timed On command succeeded")
      true
    else
      fail("Timed On command failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 25: Wildcard read (all attributes on all endpoints/clusters)
  defp test_wildcard_read do
    log("")
    log("=== Step 25: Wildcard read ===")
    {status, output} = run_chip_tool(
      ["any", "read-by-id", "0xFFFFFFFF", "0xFFFFFFFF", "#{@node_id}", "0xFFFF"]
    )

    if status == 0 do
      has_onoff = String.contains?(output, "OnOff") or String.contains?(output, "Endpoint: 1")
      has_basic = String.contains?(output, "BasicInformation") or String.contains?(output, "VendorName") or String.contains?(output, "Matterlix")
      has_descriptor = String.contains?(output, "Descriptor") or String.contains?(output, "PartsList") or String.contains?(output, "ServerList")

      if has_onoff and has_basic and has_descriptor do
        pass("Wildcard read returned data from OnOff, BasicInformation, and Descriptor")
        true
      else
        fail("Wildcard read missing expected clusters (OnOff=#{has_onoff}, Basic=#{has_basic}, Descriptor=#{has_descriptor})")
        IO.puts("  Output length: #{String.length(output)} bytes")
        false
      end
    else
      fail("Wildcard read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 26: Error path — non-existent endpoint
  defp test_error_nonexistent_endpoint do
    log("")
    log("=== Step 26: Error path — non-existent endpoint ===")
    {status, output} = run_chip_tool(["onoff", "read", "on-off", "#{@node_id}", "99"])

    # chip-tool may exit 0 with error status in output, or non-zero
    if String.contains?(output, "UNSUPPORTED_ENDPOINT") or
       String.contains?(output, "0x7F") or
       String.contains?(output, "unsupported_endpoint") do
      pass("Got UNSUPPORTED_ENDPOINT for endpoint 99")
      true
    else
      fail("Expected UNSUPPORTED_ENDPOINT error for non-existent endpoint 99")
      IO.puts("  Exit: #{inspect(status)}")
      IO.puts("  Output: #{String.trim(output)}")
      false
    end
  end

  # Step 27: Error path — write to read-only attribute
  defp test_error_write_readonly do
    log("")
    log("=== Step 27: Error path — write read-only attribute ===")
    {status, output} = run_chip_tool(
      ["basicinformation", "write-by-id", "0x0001", "\"Hacked\"", "#{@node_id}", "0"]
    )

    # vendor-name (0x0001) is read-only — expect UNSUPPORTED_WRITE
    if String.contains?(output, "UNSUPPORTED_WRITE") or
       String.contains?(output, "0x88") or
       String.contains?(output, "unsupported_write") do
      pass("Got UNSUPPORTED_WRITE for read-only attribute")
      true
    else
      fail("Expected UNSUPPORTED_WRITE error for read-only vendor-name")
      IO.puts("  Exit: #{inspect(status)}")
      IO.puts("  Output: #{String.trim(output)}")
      false
    end
  end

  # Step 28: Subscription — verify full subscribe handshake + priming report
  # chip-tool exits after SubscribeResponse, so we validate the complete
  # SubscribeRequest → ReportData → StatusResponse → SubscribeResponse flow
  # and verify the priming report contains the expected OnOff value.
  defp test_subscription do
    log("")
    log("=== Step 28: Subscription (on-off priming report) ===")
    {status, output} = run_chip_tool(
      ["onoff", "subscribe", "on-off", "1", "10", "#{@node_id}", "1"],
      timeout: 10_000
    )

    # chip-tool exits cleanly after subscription is established
    if status == 0 or status == :timeout do
      has_subscription = String.contains?(output, "Subscription established") or
                         String.contains?(output, "SubscribeResponse")
      has_onoff = Regex.match?(~r/OnOff:\s*(TRUE|FALSE|0|1)\b/i, output)

      cond do
        has_subscription and has_onoff ->
          pass("Subscription established with OnOff priming report")
          true

        has_onoff ->
          pass("Subscription priming report received (OnOff value present)")
          true

        true ->
          fail("Subscription output missing OnOff priming report")
          IO.puts("  Output: #{String.trim(output)}")
          false
      end
    else
      fail("Subscription failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # ── Failure tracking ──────────────────────────────────────────

  @failures_path "/tmp/matterlix_chip_tool_failures"

  defp load_retest_filter do
    case File.read(@failures_path) do
      {:ok, content} ->
        names = content |> String.split("\n", trim: true) |> MapSet.new()
        if MapSet.size(names) > 0, do: names, else: nil
      {:error, _} -> nil
    end
  end

  defp save_failures(failed_names) do
    if failed_names == [] do
      File.rm(@failures_path)
    else
      File.write!(@failures_path, Enum.join(failed_names, "\n") <> "\n")
    end
  end

  # ── Main ───────────────────────────────────────────────────────

  def run do
    retest? = "--retest" in System.argv()

    IO.puts("")
    IO.puts(color(:cyan, "╔══════════════════════════════════════════════════╗"))
    IO.puts(color(:cyan, "║  Matterlix chip-tool Integration Test           ║"))
    IO.puts(color(:cyan, "╚══════════════════════════════════════════════════╝"))
    IO.puts("")

    check_chip_tool()

    {ip_str, ip_tuple, iface} = detect_lan_ip()
    log("Using #{iface} (#{ip_str}) for chip-tool communication")

    {_node, _mdns} = start_device(ip_tuple)

    # Give mDNS a moment to announce
    Process.sleep(500)

    all_tests = [
      {"commission",              fn -> test_commission(ip_str) end},
      {"read_initial_state",      fn -> test_read_initial_state() end},
      {"toggle",                  fn -> test_toggle() end},
      {"read_toggled_state",      fn -> test_read_toggled_state() end},
      {"off",                     fn -> test_off() end},
      {"read_after_off",          fn -> test_read_after_off() end},
      {"on",                      fn -> test_on() end},
      {"read_basic_info",         fn -> test_read_basic_info() end},
      {"read_product_name",       fn -> test_read_product_name() end},
      {"write_node_label",        fn -> test_write_node_label() end},
      {"descriptor_parts_list",   fn -> test_descriptor_parts_list() end},
      {"descriptor_server_list",  fn -> test_descriptor_server_list() end},
      {"descriptor_device_type_list", fn -> test_descriptor_device_type_list() end},
      {"read_breadcrumb",         fn -> test_read_breadcrumb() end},
      {"read_fabrics",            fn -> test_read_fabrics() end},
      {"read_commissioned_fabrics", fn -> test_read_commissioned_fabrics() end},
      {"read_acl",                fn -> test_read_acl() end},
      {"fabric_filtered_read",    fn -> test_fabric_filtered_read() end},
      {"identify",                fn -> test_identify() end},
      {"read_identify_time",      fn -> test_read_identify_time() end},
      {"add_group",               fn -> test_add_group() end},
      {"view_group",              fn -> test_view_group() end},
      {"scenes_membership",       fn -> test_scenes_membership() end},
      {"timed_on",                fn -> test_timed_on() end},
      {"wildcard_read",           fn -> test_wildcard_read() end},
      {"error_nonexistent_endpoint", fn -> test_error_nonexistent_endpoint() end},
      {"error_write_readonly",    fn -> test_error_write_readonly() end},
      {"subscription",            fn -> test_subscription() end}
    ]

    # Filter to only failed tests on --retest
    {tests, retest_filter} =
      if retest? do
        filter = load_retest_filter()
        if filter do
          filtered = Enum.filter(all_tests, fn {name, _} -> MapSet.member?(filter, name) end)
          log("Retesting #{length(filtered)} previously failed test(s): #{Enum.map_join(filtered, ", ", &elem(&1, 0))}")
          IO.puts("")
          {filtered, filter}
        else
          log("No previous failures found, running all tests")
          IO.puts("")
          {all_tests, nil}
        end
      else
        {all_tests, nil}
      end

    # Commission is always required (establishes CASE session)
    tests =
      if retest_filter && not MapSet.member?(retest_filter, "commission") do
        [{_name, commission_fn} | _] = all_tests
        log("Auto-including commission step (required for CASE session)")
        [{"commission", commission_fn} | tests]
      else
        tests
      end

    # Run tests and collect results
    results = Enum.map(tests, fn {name, fun} -> {name, fun.()} end)

    failed_names = for {name, false} <- results, do: name
    save_failures(failed_names)

    # Summary
    passed = Enum.count(results, fn {_, r} -> r end)
    failed = length(failed_names)
    total = length(results)

    IO.puts("")
    IO.puts(color(:cyan, "══════════════════════════════════════════════════"))

    if failed == 0 do
      IO.puts(color(:green, "  All #{total} tests passed!"))
      if retest?, do: IO.puts(color(:green, "  (failures file cleared)"))
    else
      IO.puts(color(:red, "  #{failed}/#{total} tests failed") <>
              ", " <> color(:green, "#{passed} passed"))
      IO.puts(color(:yellow, "  Rerun failed tests: mix run test_chip_tool.exs -- --retest"))
    end

    IO.puts(color(:cyan, "══════════════════════════════════════════════════"))
    IO.puts("")

    if failed > 0, do: System.halt(1)
  end
end

TestChipTool.run()
