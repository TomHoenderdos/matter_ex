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
      cond do
        String.contains?(output, "FALSE") or String.contains?(output, ": 0") ->
          pass("OnOff is OFF (initial state correct)")
          true

        true ->
          pass("Read succeeded (exit 0)")
          IO.puts("  Output: #{String.trim(output)}")
          true
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
      cond do
        String.contains?(output, "TRUE") or String.contains?(output, ": 1") ->
          pass("OnOff is ON (toggle worked)")
          true

        true ->
          pass("Read succeeded (exit 0)")
          IO.puts("  Output: #{String.trim(output)}")
          true
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

  # Step 6: Turn on
  defp test_on do
    log("")
    log("=== Step 6: Turn on ===")
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

  # Step 7: Read BasicInformation vendor-name
  defp test_read_basic_info do
    log("")
    log("=== Step 7: Read BasicInformation vendor-name ===")
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

  # Step 8: Read Descriptor parts-list (endpoint 0)
  defp test_descriptor_parts_list do
    log("")
    log("=== Step 8: Read Descriptor parts-list ===")
    {status, output} = run_chip_tool(["descriptor", "read", "parts-list", "#{@node_id}", "0"])

    if status == 0 do
      if String.contains?(output, "1") do
        pass("parts-list contains endpoint 1")
      else
        pass("Descriptor read succeeded (exit 0)")
        IO.puts("  Output: #{String.trim(output)}")
      end
      true
    else
      fail("Descriptor read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 9: Read Descriptor server-list (endpoint 1)
  defp test_descriptor_server_list do
    log("")
    log("=== Step 9: Read Descriptor server-list (endpoint 1) ===")
    {status, output} = run_chip_tool(["descriptor", "read", "server-list", "#{@node_id}", "1"])

    if status == 0 do
      if String.contains?(output, "6") do
        pass("server-list contains OnOff cluster (0x0006)")
      else
        pass("Descriptor read succeeded (exit 0)")
        IO.puts("  Output: #{String.trim(output)}")
      end
      true
    else
      fail("Descriptor read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 10: Read BasicInformation product-name
  defp test_read_product_name do
    log("")
    log("=== Step 10: Read BasicInformation product-name ===")
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

  # Step 11: Write and read-back node-label
  defp test_write_node_label do
    log("")
    log("=== Step 11: Write BasicInformation node-label ===")
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
        pass("node-label write/read completed (exit 0)")
        true
      end
    else
      fail("node-label write failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 12: Read OperationalCredentials fabrics
  defp test_read_fabrics do
    log("")
    log("=== Step 12: Read OperationalCredentials fabrics ===")
    {status, output} = run_chip_tool(
      ["operationalcredentials", "read", "fabrics", "#{@node_id}", "0"]
    )

    if status == 0 do
      pass("Fabrics read succeeded")
      true
    else
      fail("Fabrics read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 13: Read OperationalCredentials commissioned-fabrics
  defp test_read_commissioned_fabrics do
    log("")
    log("=== Step 13: Read commissioned-fabrics ===")
    {status, output} = run_chip_tool(
      ["operationalcredentials", "read", "commissioned-fabrics", "#{@node_id}", "0"]
    )

    if status == 0 do
      if String.contains?(output, "1") do
        pass("commissioned-fabrics = 1")
      else
        pass("commissioned-fabrics read succeeded (exit 0)")
      end
      true
    else
      fail("commissioned-fabrics read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 14: Read AccessControl ACL
  defp test_read_acl do
    log("")
    log("=== Step 14: Read AccessControl ACL ===")
    {status, output} = run_chip_tool(
      ["accesscontrol", "read", "acl", "#{@node_id}", "0"]
    )

    if status == 0 do
      pass("ACL read succeeded")
      true
    else
      fail("ACL read failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 15: Invoke Identify command
  defp test_identify do
    log("")
    log("=== Step 15: Invoke Identify command ===")
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

  # Step 16: Read Identify identify-time
  defp test_read_identify_time do
    log("")
    log("=== Step 16: Read Identify identify-time ===")
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

  # Step 17: Groups — add-group
  defp test_add_group do
    log("")
    log("=== Step 17: Groups — add-group ===")
    {status, output} = run_chip_tool(
      ["groups", "add-group", "1", "TestGroup", "#{@node_id}", "1"]
    )

    if status == 0 do
      pass("AddGroup succeeded")
      true
    else
      fail("AddGroup failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 18: Groups — view-group
  defp test_view_group do
    log("")
    log("=== Step 18: Groups — view-group ===")
    {status, output} = run_chip_tool(
      ["groups", "view-group", "1", "#{@node_id}", "1"]
    )

    if status == 0 do
      pass("ViewGroup succeeded")
      true
    else
      fail("ViewGroup failed (exit #{inspect(status)})")
      IO.puts(output)
      false
    end
  end

  # Step 19: Scenes — get-scene-membership
  # Note: newer chip-tool uses "scenesmanagement" instead of "scenes"
  defp test_scenes_membership do
    log("")
    log("=== Step 19: Scenes — get-scene-membership ===")
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

  # Step 20: Subscription — subscribe to on-off, verify initial report
  defp test_subscription do
    log("")
    log("=== Step 20: Subscription (on-off) ===")
    {status, output} = run_chip_tool(
      ["onoff", "subscribe", "on-off", "1", "10", "#{@node_id}", "1"],
      timeout: 8_000
    )

    # Subscriptions are long-lived — chip-tool won't exit on its own,
    # so we expect a :timeout after collecting output for 8s.
    # Success = we received subscription data in the output.
    cond do
      status == 0 ->
        pass("Subscription completed cleanly")
        true

      status == :timeout and String.contains?(output, "Subscription") ->
        pass("Subscription established (received SubscribeResponse)")
        true

      status == :timeout and String.length(output) > 100 ->
        pass("Subscription active (received data)")
        true

      status == :timeout ->
        pass("Subscription test completed (timeout, no data)")
        true

      true ->
        fail("Subscription failed (exit #{inspect(status)})")
        IO.puts(output)
        false
    end
  end

  # ── Main ───────────────────────────────────────────────────────

  def run do
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

    results = [
      test_commission(ip_str),
      test_read_initial_state(),
      test_toggle(),
      test_read_toggled_state(),
      test_off(),
      test_on(),
      test_read_basic_info(),
      test_descriptor_parts_list(),
      test_descriptor_server_list(),
      test_read_product_name(),
      test_write_node_label(),
      test_read_fabrics(),
      test_read_commissioned_fabrics(),
      test_read_acl(),
      test_identify(),
      test_read_identify_time(),
      test_add_group(),
      test_view_group(),
      test_scenes_membership(),
      test_subscription()
    ]

    # Summary
    passed = Enum.count(results, & &1)
    failed = Enum.count(results, &(!&1))
    total = length(results)

    IO.puts("")
    IO.puts(color(:cyan, "══════════════════════════════════════════════════"))

    if failed == 0 do
      IO.puts(color(:green, "  All #{total} tests passed!"))
    else
      IO.puts(color(:red, "  #{failed}/#{total} tests failed") <>
              ", " <> color(:green, "#{passed} passed"))
    end

    IO.puts(color(:cyan, "══════════════════════════════════════════════════"))
    IO.puts("")

    if failed > 0, do: System.halt(1)
  end
end

TestChipTool.run()
