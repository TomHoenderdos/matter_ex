# Automated MatterEx smoke test using chip-tool.
#
# Local host test:
#   mix run scripts/matter_smoke.exs
#
# Remote device test, for example a Pi running examples/net_test:
#   mix run scripts/matter_smoke.exs -- --mode remote --host 192.168.1.42
#
# BLE Wi-Fi commissioning test:
#   MATTER_WIFI_PASSWORD=secret mix run scripts/matter_smoke.exs -- \
#     --mode remote --commissioning ble-wifi --wifi-ssid MyWifi

defmodule MatterExSmoke do
  defmodule Light do
    use MatterEx.Device,
      vendor_name: "MatterEx",
      product_name: "Smoke Light",
      vendor_id: 0xFFF1,
      product_id: 0x8001

    endpoint 1, device_type: 0x0100 do
      cluster(MatterEx.Cluster.OnOff)
      cluster(MatterEx.Cluster.Identify)
    end
  end

  @defaults %{
    mode: "local",
    host: nil,
    port: 5540,
    node_id: 111,
    passcode: 20_202_021,
    discriminator: 3840,
    commissioning: "already-discovered",
    wifi_ssid: nil,
    wifi_password: nil,
    chip_tool: "chip-tool",
    commissioner: nil,
    timeout: 6_000,
    commission_timeout: 20_000,
    storage_directory: "/tmp/matter_ex_smoke_kvs",
    clean_storage: true,
    fail_fast: true,
    verbose: false,
    output_lines: 80
  }

  def run(argv) do
    opts = parse_args(argv)
    check_chip_tool!(opts)

    {host, cleanup} =
      case opts.mode do
        "local" -> start_local_device(opts)
        "remote" -> {remote_host(opts), fn -> :ok end}
        other -> abort!("Unknown --mode #{inspect(other)}. Use local or remote.")
      end

    prepare_storage!(opts)

    results = [
      {"commission", fn -> commission(opts, host) end},
      {"turn off", fn -> command(opts, ["onoff", "off", node_id(opts), "1"]) end},
      {"read off", fn -> read_onoff(opts, false) end},
      {"turn on", fn -> command(opts, ["onoff", "on", node_id(opts), "1"]) end},
      {"read on", fn -> read_onoff(opts, true) end},
      {"turn off", fn -> command(opts, ["onoff", "off", node_id(opts), "1"]) end},
      {"read off", fn -> read_onoff(opts, false) end},
      {"read basic information", fn -> read_basic_information(opts) end}
    ]

    failures = run_steps(results, opts)
    cleanup.()

    if failures == [] do
      IO.puts("\nPASS: MatterEx smoke test passed")
    else
      IO.puts("\nFAIL: #{length(failures)} smoke step(s) failed: #{Enum.join(failures, ", ")}")
      System.halt(1)
    end
  end

  defp parse_args(argv) do
    argv = if List.first(argv) == "--", do: tl(argv), else: argv

    {parsed, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          mode: :string,
          host: :string,
          port: :integer,
          node_id: :integer,
          passcode: :integer,
          discriminator: :integer,
          commissioning: :string,
          wifi_ssid: :string,
          wifi_password: :string,
          chip_tool: :string,
          commissioner: :string,
          timeout: :integer,
          commission_timeout: :integer,
          storage_directory: :string,
          keep_storage: :boolean,
          no_fail_fast: :boolean,
          verbose: :boolean,
          output_lines: :integer,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    if parsed[:help] || rest != [] || invalid != [] do
      usage()
      System.halt(if parsed[:help], do: 0, else: 1)
    end

    @defaults
    |> Map.merge(Map.new(parsed))
    |> Map.update!(:wifi_password, fn password ->
      password || System.get_env("MATTER_WIFI_PASSWORD")
    end)
    |> Map.update!(:clean_storage, fn clean ->
      clean && !Keyword.get(parsed, :keep_storage, false)
    end)
    |> Map.update!(:fail_fast, fn fail_fast ->
      fail_fast && !Keyword.get(parsed, :no_fail_fast, false)
    end)
  end

  defp usage do
    IO.puts("""
    Usage:
      mix run scripts/matter_smoke.exs
      mix run scripts/matter_smoke.exs -- --mode remote --host 192.168.1.42

    Options:
      --mode local|remote           Start a local test device or test an existing device
      --host IP_OR_HOST             Required for remote already-discovered commissioning
      --port PORT                   Matter UDP port, default 5540
      --node-id ID                  chip-tool node id, default 111
      --passcode PASSCODE           Setup passcode, default 20202021
      --discriminator VALUE         Local mode discriminator, default 3840
      --commissioning MODE          already-discovered or ble-wifi, default already-discovered
      --wifi-ssid SSID              Required for --commissioning ble-wifi
      --wifi-password PASSWORD      Wi-Fi password, or MATTER_WIFI_PASSWORD env var
      --chip-tool PATH              chip-tool executable path, default chip-tool
      --commissioner SSH_HOST       Run chip-tool over SSH, for example pi@192.168.0.3
      --timeout MS                  Per-command timeout after commissioning, default 6000
      --commission-timeout MS       Commissioning timeout, default 20000
      --storage-directory PATH      chip-tool storage directory
      --keep-storage                Reuse chip-tool storage between runs
      --no-fail-fast                Continue after failures for a full report
      --verbose                     Print full chip-tool output on failure
      --output-lines N              Failure output tail length, default 80
    """)
  end

  defp check_chip_tool!(%{commissioner: commissioner}) when is_binary(commissioner) do
    unless System.find_executable("ssh") do
      abort!("ssh not found. Install OpenSSH or omit --commissioner.")
    end
  end

  defp check_chip_tool!(%{chip_tool: chip_tool}) do
    cond do
      Path.type(chip_tool) == :absolute && File.exists?(chip_tool) ->
        :ok

      System.find_executable(chip_tool) ->
        :ok

      true ->
        abort!("#{chip_tool} not found. Install chip-tool or pass --chip-tool PATH.")
    end
  end

  defp prepare_storage!(%{commissioner: commissioner} = opts) when is_binary(commissioner) do
    command =
      if opts.clean_storage do
        "rm -rf -- #{shell_quote(opts.storage_directory)} && mkdir -p -- #{shell_quote(opts.storage_directory)}"
      else
        "mkdir -p -- #{shell_quote(opts.storage_directory)}"
      end

    args = ssh_args(commissioner, command)

    case System.cmd(System.find_executable("ssh"), args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> abort!("Failed to prepare remote storage, exit #{status}:\n#{output}")
    end
  end

  defp prepare_storage!(opts) do
    if opts.clean_storage do
      File.rm_rf!(opts.storage_directory)
    end

    File.mkdir_p!(opts.storage_directory)
  end

  defp start_local_device(opts) do
    {host, ip_tuple, iface} = detect_lan_ip()
    IO.puts("Starting local MatterEx smoke device on #{iface} (#{host})")

    {:ok, _device} = Light.start_link()
    {:ok, mdns} = MatterEx.MDNS.start_link(addresses: [ip_tuple])

    service =
      MatterEx.MDNS.commissioning_service(
        port: opts.port,
        discriminator: opts.discriminator,
        vendor_id: 0xFFF1,
        product_id: 0x8001,
        device_name: "MatterEx Smoke Light",
        device_type: 0x0100
      )

    MatterEx.MDNS.advertise(mdns, service)

    {:ok, node} =
      MatterEx.Node.start_link(
        device: Light,
        passcode: opts.passcode,
        salt: :crypto.strong_rand_bytes(32),
        iterations: 1000,
        port: opts.port,
        mdns: mdns,
        commissioning_instance: Keyword.fetch!(service, :instance)
      )

    actual_port = MatterEx.Node.port(node)
    if actual_port != opts.port, do: abort!("Expected port #{opts.port}, got #{actual_port}")
    Process.sleep(500)

    {host,
     fn ->
       Process.exit(node, :normal)
       Process.exit(mdns, :normal)
     end}
  end

  defp required_host!(%{host: host}) when is_binary(host) and byte_size(host) > 0, do: host
  defp required_host!(_opts), do: abort!("--host is required when --mode remote")

  defp remote_host(%{commissioning: "ble-wifi"} = opts), do: opts.host || "ble-wifi"
  defp remote_host(opts), do: required_host!(opts)

  defp detect_lan_ip do
    {:ok, ifaddrs} = :inet.getifaddrs()

    ifaddrs
    |> Enum.flat_map(fn {name, opts} ->
      opts |> Keyword.get_values(:addr) |> Enum.map(&{to_string(name), &1})
    end)
    |> Enum.find(fn
      {_name, {127, _, _, _}} ->
        false

      {name, {a, _, _, _}} when a > 0 and a < 255 ->
        String.starts_with?(name, "en") or String.starts_with?(name, "eth")

      _ ->
        false
    end)
    |> case do
      {name, ip} -> {:inet.ntoa(ip) |> to_string(), ip, name}
      nil -> {"127.0.0.1", {127, 0, 0, 1}, "loopback"}
    end
  end

  defp commission(opts, host) do
    case opts.commissioning do
      "already-discovered" ->
        command(
          opts,
          [
            "pairing",
            "already-discovered",
            node_id(opts),
            Integer.to_string(opts.passcode),
            host,
            Integer.to_string(opts.port),
            "--bypass-attestation-verifier",
            "true"
          ],
          timeout: opts.commission_timeout
        )

      "ble-wifi" ->
        ssid = required_wifi_ssid!(opts)
        password = required_wifi_password!(opts)

        command(
          opts,
          [
            "pairing",
            "ble-wifi",
            node_id(opts),
            ssid,
            password,
            Integer.to_string(opts.passcode),
            Integer.to_string(opts.discriminator),
            "--bypass-attestation-verifier",
            "true"
          ],
          timeout: opts.commission_timeout
        )

      other ->
        {:error, "Unknown --commissioning #{inspect(other)}"}
    end
  end

  defp required_wifi_ssid!(%{wifi_ssid: ssid}) when is_binary(ssid) and byte_size(ssid) > 0,
    do: ssid

  defp required_wifi_ssid!(_opts),
    do: abort!("--wifi-ssid is required for --commissioning ble-wifi")

  defp required_wifi_password!(%{wifi_password: password})
       when is_binary(password) and byte_size(password) > 0,
       do: password

  defp required_wifi_password!(_opts),
    do: abort!("--wifi-password or MATTER_WIFI_PASSWORD is required for --commissioning ble-wifi")

  defp read_onoff(opts, expected) do
    case command(opts, ["onoff", "read", "on-off", node_id(opts), "1"]) do
      {:ok, output} ->
        expected_pattern =
          if expected, do: ~r/OnOff:\s*(TRUE|1)\b/i, else: ~r/OnOff:\s*(FALSE|0)\b/i

        if Regex.match?(expected_pattern, output) do
          :ok
        else
          {:error, "Expected OnOff=#{expected}, got:\n#{trim_output(output)}"}
        end

      error ->
        error
    end
  end

  defp read_basic_information(opts) do
    case command(opts, ["basicinformation", "read", "vendor-name", node_id(opts), "0"]) do
      {:ok, output} ->
        if String.contains?(output, "MatterEx") do
          :ok
        else
          {:error, "VendorName did not contain MatterEx:\n#{trim_output(output)}"}
        end

      error ->
        error
    end
  end

  defp command(opts, args, command_opts \\ []) do
    timeout = Keyword.get(command_opts, :timeout, opts.timeout)
    full_args = args ++ ["--storage-directory", opts.storage_directory]
    print_command(opts, full_args)
    deadline = System.monotonic_time(:millisecond) + timeout

    {executable, port_args} = command_invocation(opts, full_args)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: port_args
      ])

    case collect_output(port, "", deadline) do
      {0, output} ->
        {:ok, output}

      {:timeout, output} ->
        {:error, "Timed out after #{timeout}ms:\n#{format_output(output, opts)}"}

      {status, output} ->
        {:error, "Exited #{inspect(status)}:\n#{format_output(output, opts)}"}
    end
  end

  defp chip_tool_path(%{chip_tool: chip_tool}) do
    if Path.type(chip_tool) == :absolute do
      chip_tool
    else
      System.find_executable(chip_tool) || chip_tool
    end
  end

  defp command_invocation(%{commissioner: commissioner} = opts, full_args)
       when is_binary(commissioner) do
    remote_command =
      [opts.chip_tool | full_args]
      |> Enum.map(&shell_quote/1)
      |> Enum.join(" ")

    {System.find_executable("ssh"), ssh_args(commissioner, remote_command)}
  end

  defp command_invocation(opts, full_args), do: {chip_tool_path(opts), full_args}

  defp print_command(%{commissioner: commissioner} = opts, full_args)
       when is_binary(commissioner) do
    masked =
      [opts.chip_tool | mask_sensitive_args(opts, full_args)]
      |> Enum.map(&shell_quote/1)
      |> Enum.join(" ")

    IO.puts("$ ssh #{commissioner} #{masked}")
  end

  defp print_command(opts, full_args) do
    IO.puts("$ #{opts.chip_tool} #{Enum.join(mask_sensitive_args(opts, full_args), " ")}")
  end

  defp shell_quote(arg) do
    "'" <> String.replace(to_string(arg), "'", "'\"'\"'") <> "'"
  end

  defp ssh_args(commissioner, remote_command) do
    [
      "-o",
      "UserKnownHostsFile=/tmp/matter_ex_rpios_known_hosts",
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "BatchMode=yes",
      commissioner,
      remote_command
    ]
  end

  defp mask_sensitive_args(%{wifi_password: password}, args)
       when is_binary(password) and byte_size(password) > 0 do
    Enum.map(args, fn
      ^password -> "********"
      arg -> arg
    end)
  end

  defp mask_sensitive_args(_opts, args), do: args

  defp collect_output(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect_output(port, acc <> data, deadline)
      {^port, {:exit_status, status}} -> {status, acc}
    after
      remaining ->
        Port.close(port)
        {:timeout, acc}
    end
  end

  defp format_output(output, %{verbose: true}), do: trim_output(output)

  defp format_output(output, opts) do
    output = trim_output(output)
    lines = String.split(output, "\n")

    if length(lines) <= opts.output_lines do
      output
    else
      lines
      |> Enum.take(-opts.output_lines)
      |> then(fn tail ->
        "... output truncated to last #{opts.output_lines} lines. Pass --verbose for full output.\n" <>
          Enum.join(tail, "\n")
      end)
    end
  end

  defp trim_output(output), do: output |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.trim()

  defp run_steps(steps, opts) do
    Enum.reduce_while(steps, [], fn {name, fun}, failures ->
      IO.puts("\n== #{name} ==")

      case fun.() do
        :ok ->
          IO.puts("PASS #{name}")
          {:cont, failures}

        {:ok, _output} ->
          IO.puts("PASS #{name}")
          {:cont, failures}

        {:error, reason} ->
          IO.puts("FAIL #{name}\n#{reason}")
          failures = [name | failures]

          if opts.fail_fast do
            IO.puts("Stopping after first failure. Pass --no-fail-fast for a full report.")
            {:halt, failures}
          else
            {:cont, failures}
          end
      end
    end)
    |> Enum.reverse()
  end

  defp node_id(opts), do: Integer.to_string(opts.node_id)

  defp abort!(message) do
    IO.puts(:stderr, "ERROR: #{message}")
    System.halt(1)
  end
end

MatterExSmoke.run(System.argv())
