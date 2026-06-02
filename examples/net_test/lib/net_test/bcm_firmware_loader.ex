defmodule NetTest.BcmFirmwareLoader do
  @moduledoc """
  Downloads Broadcom patchram firmware (.hcd) to the BCM4345C5 BLE chip
  over HCI UART before BlueHeron starts.

  The BCM4345C5 on RPi 4 boots into ROM mode and requires firmware download
  via vendor-specific HCI commands (Download Minidriver → Write_RAM chunks →
  Launch_RAM). After launch, the chip soft-reboots into the patched firmware
  and responds to standard HCI commands.
  """

  require Logger

  @hcd_path "/lib/firmware/brcm/BCM4345C5.hcd"

  # HCI packet types
  @hci_command_pkt 0x01
  @hci_event_pkt 0x04
  @command_complete 0x0E

  def load(uart_device, speed \\ 115_200) do
    unless File.exists?(@hcd_path) do
      Logger.warning("BCM firmware not found at #{@hcd_path}, skipping download")
      :ok
    else
      do_load(uart_device, speed)
    end
  end

  defp do_load(uart_device, speed) do
    Logger.info("BCM firmware loader: opening #{uart_device} at #{speed}")

    {:ok, uart} = Circuits.UART.start_link()

    case Circuits.UART.open(uart, uart_device, speed: speed, active: false) do
      :ok ->
        result = run_download(uart)
        Circuits.UART.close(uart)
        GenServer.stop(uart)
        result

      {:error, reason} ->
        GenServer.stop(uart)
        Logger.error("BCM firmware loader: failed to open UART: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_download(uart) do
    # Step 1: HCI Reset
    Logger.info("BCM firmware: sending HCI Reset")
    flush_uart(uart)

    with :ok <- send_command(uart, <<0x03, 0x0C, 0x00>>),
         {:ok, _} <- wait_command_complete(uart, <<0x03, 0x0C>>, 2000) do
      Process.sleep(100)
      Logger.info("BCM firmware: HCI Reset OK")
    else
      {:error, reason} ->
        Logger.warning(
          "BCM firmware: HCI Reset failed (#{inspect(reason)}), retrying after flush"
        )

        flush_uart(uart)
        Process.sleep(100)

        # Retry once
        :ok = send_command(uart, <<0x03, 0x0C, 0x00>>)

        case wait_command_complete(uart, <<0x03, 0x0C>>, 2000) do
          {:ok, _} ->
            Process.sleep(100)
            Logger.info("BCM firmware: HCI Reset OK (retry)")

          {:error, reason2} ->
            Logger.error("BCM firmware: HCI Reset failed: #{inspect(reason2)}")
            return_error(reason2)
        end
    end

    # Step 2: Download Minidriver (enters firmware download mode)
    Logger.info("BCM firmware: sending Download Minidriver")
    :ok = send_command(uart, <<0x2E, 0xFC, 0x00>>)

    case wait_command_complete(uart, <<0x2E, 0xFC>>, 5000) do
      {:ok, _} ->
        Process.sleep(50)
        Logger.info("BCM firmware: Download Minidriver OK")

      {:error, reason} ->
        Logger.error("BCM firmware: Download Minidriver failed: #{inspect(reason)}")
        return_error(reason)
    end

    # Step 3: Send HCD file contents
    hcd_data = File.read!(@hcd_path)
    hcd_size = byte_size(hcd_data)
    Logger.info("BCM firmware: loading #{hcd_size} bytes from #{@hcd_path}")

    case send_hcd_commands(uart, hcd_data, 0) do
      {:ok, count} ->
        Logger.info("BCM firmware: sent #{count} commands from HCD file")

      {:error, reason} ->
        Logger.error("BCM firmware: HCD download failed: #{inspect(reason)}")
        return_error(reason)
    end

    # Step 4: Wait for chip to soft-reboot with patched firmware
    Logger.info("BCM firmware: waiting for chip reboot...")
    Process.sleep(500)
    flush_uart(uart)

    # Step 5: HCI Reset (chip now running patched firmware)
    Logger.info("BCM firmware: sending post-download HCI Reset")
    :ok = send_command(uart, <<0x03, 0x0C, 0x00>>)

    case wait_command_complete(uart, <<0x03, 0x0C>>, 5000) do
      {:ok, _} ->
        Process.sleep(100)
        Logger.info("BCM firmware: download complete, chip running patched firmware")
        :ok

      {:error, reason} ->
        Logger.error("BCM firmware: post-download HCI Reset failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_hcd_commands(_uart, <<>>, count), do: {:ok, count}

  defp send_hcd_commands(uart, <<opcode::binary-size(2), plen::8, rest::binary>>, count) do
    <<params::binary-size(plen), remaining::binary>> = rest

    :ok = send_command(uart, <<opcode::binary, plen, params::binary>>)

    case wait_command_complete(uart, opcode, 5000) do
      {:ok, _} ->
        # Generous inter-command delay for mini-UART (no flow control)
        Process.sleep(5)
        send_hcd_commands(uart, remaining, count + 1)

      {:error, reason} ->
        Logger.error(
          "BCM firmware: command #{count + 1} (opcode 0x#{Base.encode16(opcode)}) failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp send_command(uart, <<opcode::binary-size(2), _::binary>> = command_data) do
    packet = <<@hci_command_pkt, command_data::binary>>

    Logger.debug("BCM fw TX: 0x#{Base.encode16(packet)} (opcode 0x#{Base.encode16(opcode)})")

    Circuits.UART.write(uart, packet)
  end

  defp wait_command_complete(uart, expected_opcode, timeout) do
    # Read raw bytes and parse HCI event
    # Event format: 04 <event_code> <param_len> <params...>
    deadline = System.monotonic_time(:millisecond) + timeout
    read_event(uart, expected_opcode, deadline, <<>>)
  end

  defp read_event(uart, expected_opcode, deadline, buffer) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, {:timeout, buffer}}
    else
      read_timeout = min(remaining_ms, 1000)

      case Circuits.UART.read(uart, read_timeout) do
        {:ok, <<>>} ->
          # Empty read, try again
          read_event(uart, expected_opcode, deadline, buffer)

        {:ok, data} ->
          new_buffer = buffer <> data
          try_parse_event(uart, expected_opcode, deadline, new_buffer)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp try_parse_event(uart, expected_opcode, deadline, buffer) do
    case buffer do
      # Skip non-event bytes (find event indicator)
      <<byte, rest::binary>> when byte != @hci_event_pkt ->
        try_parse_event(uart, expected_opcode, deadline, rest)

      # CommandComplete event with enough data
      <<@hci_event_pkt, @command_complete, plen, params::binary-size(plen), _rest::binary>>
      when plen >= 3 ->
        <<_ncmd, opcode::binary-size(2), status, _::binary>> = params

        Logger.debug(
          "BCM fw RX: CommandComplete opcode=0x#{Base.encode16(opcode)} status=#{status}"
        )

        if opcode == expected_opcode do
          if status == 0x00 do
            {:ok, params}
          else
            {:error, {:hci_status, status, opcode}}
          end
        else
          # Wrong opcode, skip and keep reading
          Logger.debug("BCM fw: ignoring CommandComplete for 0x#{Base.encode16(opcode)}")
          <<_skip::binary-size(3 + plen), rest::binary>> = buffer
          read_event(uart, expected_opcode, deadline, rest)
        end

      # Have event header but not enough data yet
      <<@hci_event_pkt, _event_code, plen, rest::binary>> when byte_size(rest) < plen ->
        read_event(uart, expected_opcode, deadline, buffer)

      # Non-CommandComplete event, skip it
      <<@hci_event_pkt, _event_code, plen, _params::binary-size(plen), rest::binary>> ->
        read_event(uart, expected_opcode, deadline, rest)

      # Not enough data yet
      _ ->
        read_event(uart, expected_opcode, deadline, buffer)
    end
  end

  defp flush_uart(uart) do
    Circuits.UART.flush(uart, :both)
    # Also drain any pending data
    drain(uart)
  end

  defp drain(uart) do
    case Circuits.UART.read(uart, 50) do
      {:ok, <<>>} -> :ok
      {:ok, _data} -> drain(uart)
      {:error, _} -> :ok
    end
  end

  defp return_error(reason) do
    throw({:firmware_error, reason})
  end
end
