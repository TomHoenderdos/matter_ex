defmodule MatterEx.MDNS do
  @moduledoc """
  mDNS responder GenServer for DNS-SD service discovery.

  Opens a multicast UDP socket on port 5353 (configurable), joins the
  mDNS multicast group (224.0.0.251), and responds to DNS queries for
  registered services. Sends gratuitous announcements when services
  are added or removed.

  Includes Matter-specific helpers for building commissioning discovery
  service configurations.

  ## Example

      {:ok, mdns} = MatterEx.MDNS.start_link(
        hostname: "matter_ex-device",
        addresses: [{192, 168, 1, 100}]
      )

      # Advertise a Matter commissioning service
      service = MatterEx.MDNS.commissioning_service(
        port: 5540,
        discriminator: 3840,
        vendor: :test,
        product: :smart_light,
        device_name: "Test Light"
      )

      MatterEx.MDNS.advertise(mdns, service)
  """

  use GenServer

  import Bitwise

  require Logger

  alias MatterEx.MDNS.DNS

  @mdns_port 5353
  @mdns_multicast {224, 0, 0, 251}
  @mdns_multicast6 {0xFF02, 0, 0, 0, 0, 0, 0, 0x00FB}
  @ipproto_ipv6 41
  @sol_socket 1
  @so_bindtodevice 25
  @ipv6_multicast_if 17
  @ipv6_join_group 20
  @default_ttl 120
  @ptr_ttl 4500

  defmodule State do
    @moduledoc false
    defstruct [
      :socket,
      :socket6,
      :port,
      :hostname,
      :dynamic_addresses,
      :interface,
      services: %{},
      addresses: []
    ]
  end

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Start the mDNS responder.

  Options:
  - `:hostname` — local hostname without `.local` suffix (default: auto-generated)
  - `:port` — mDNS port (default: 5353, use 0 for OS-assigned in tests)
  - `:addresses` — list of IP tuples to advertise (default: auto-detect)
  - `:interface` — which interface(s) to auto-detect addresses from: `nil` for every
    interface, a single name (`"wlan0"`), or a list to advertise from several
    (`["wlan0", "eth0"]`)
  - `:name` — GenServer name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Get the port the mDNS responder is listening on.
  """
  @spec port(GenServer.server()) :: non_neg_integer()
  def port(server) do
    GenServer.call(server, :get_port)
  end

  @doc """
  Register a service for advertisement. Sends a gratuitous announcement.

  Options:
  - `:service` — service type (e.g. `"_matterc._udp.local"`)
  - `:instance` — instance name (e.g. `"MATTER-0F00"`)
  - `:port` — service port (e.g. 5540)
  - `:txt` — TXT record entries (e.g. `["D=3840", "CM=1"]`)
  - `:subtypes` — subtype service names for additional PTR records (optional)
  """
  @spec advertise(GenServer.server(), keyword()) :: :ok
  def advertise(server, opts) do
    GenServer.call(server, {:advertise, opts})
  end

  @doc """
  Re-announce every currently-advertised service, refreshing network state first.

  Nudges controllers to re-resolve the device — e.g. after a new DHCP lease
  changed its address, or when a controller missed the announcement burst sent at
  advertise time.
  """
  @spec reannounce_all(GenServer.server()) :: :ok
  def reannounce_all(server) do
    GenServer.cast(server, :reannounce_all)
  end

  @doc """
  Remove a service by instance name. Sends goodbye announcement (TTL=0).
  """
  @spec withdraw(GenServer.server(), String.t()) :: :ok
  def withdraw(server, instance) do
    GenServer.call(server, {:withdraw, instance})
  end

  @doc """
  Update TXT records for an existing service.
  """
  @spec update_txt(GenServer.server(), String.t(), [String.t()]) :: :ok
  def update_txt(server, instance, txt_entries) do
    GenServer.call(server, {:update_txt, instance, txt_entries})
  end

  # ── Matter DNS-SD Helpers ───────────────────────────────────────

  @doc """
  Build service configuration for Matter commissioning discovery.

  Returns keyword list suitable for `advertise/2`.

  Options:
  - `:port` — UDP port the Matter node listens on (required)
  - `:discriminator` — 12-bit commissioning discriminator (required)
  - `:vendor` — known vendor alias, or `:vendor_id` with a 16-bit ID (required)
  - `:product` — known product alias, or `:product_id` with a 16-bit ID (required)
  - `:device_name` — human-readable device name (optional)
  - `:device_type` — device type ID (optional)
  - `:commissioning_mode` — 1 (basic) or 2 (enhanced), default 1
  """
  @spec commissioning_service(keyword()) :: keyword()
  def commissioning_service(opts) do
    port = Keyword.fetch!(opts, :port)
    discriminator = Keyword.fetch!(opts, :discriminator)
    vendor_id = resolve_vendor_id!(opts)
    product_id = resolve_product_id!(opts)
    device_name = Keyword.get(opts, :device_name)
    device_type = Keyword.get(opts, :device_type)
    cm = Keyword.get(opts, :commissioning_mode, 1)

    # Generate random instance name
    instance = Base.encode16(:crypto.strong_rand_bytes(8))

    # Build TXT records
    txt = [
      "D=#{discriminator}",
      "VP=#{vendor_id}+#{product_id}",
      "CM=#{cm}",
      "T=1"
    ]

    txt = if device_type, do: txt ++ ["DT=#{device_type}"], else: txt
    txt = if device_name, do: txt ++ ["DN=#{device_name}"], else: txt

    # Build subtypes for discriminator-based discovery
    short_discriminator = discriminator >>> 8

    subtypes = [
      "_S#{short_discriminator}._sub._matterc._udp.local",
      "_L#{discriminator}._sub._matterc._udp.local"
    ]

    [
      service: "_matterc._udp.local",
      instance: instance,
      port: port,
      txt: txt,
      subtypes: subtypes
    ]
  end

  defp resolve_vendor_id!(opts) do
    cond do
      Keyword.has_key?(opts, :vendor_id) -> Keyword.fetch!(opts, :vendor_id)
      Keyword.has_key?(opts, :vendor) -> MatterEx.Device.vendor_id!(Keyword.fetch!(opts, :vendor))
      true -> Keyword.fetch!(opts, :vendor_id)
    end
  end

  defp resolve_product_id!(opts) do
    cond do
      Keyword.has_key?(opts, :product_id) ->
        Keyword.fetch!(opts, :product_id)

      Keyword.has_key?(opts, :product) ->
        MatterEx.Device.product_id!(Keyword.fetch!(opts, :product))

      true ->
        Keyword.fetch!(opts, :product_id)
    end
  end

  @doc """
  Build service configuration for Matter operational discovery.

  After commissioning, the device advertises on `_matter._tcp.local`
  with a compressed fabric ID + node ID instance name. chip-tool uses
  this to find the device for CASE session establishment.

  Options:
  - `:port` — UDP port the Matter node listens on (required)
  - `:compressed_fabric_id` — 8-byte compressed fabric identifier (required)
  - `:node_id` — operational node ID (required)
  """
  @spec operational_service(keyword()) :: keyword()
  def operational_service(opts) do
    port = Keyword.fetch!(opts, :port)
    compressed_fabric_id = Keyword.fetch!(opts, :compressed_fabric_id)
    node_id = Keyword.fetch!(opts, :node_id)

    # Instance name: <compressed-fabric-id-hex>-<node-id-hex>
    cfid_hex = Base.encode16(compressed_fabric_id)
    node_hex = node_id |> Integer.to_string(16) |> String.pad_leading(16, "0")
    instance = "#{cfid_hex}-#{node_hex}"

    txt = [
      "SII=#{5000}",
      "SAI=#{300}",
      "T=1"
    ]

    subtypes = [
      "_I#{cfid_hex}._sub._matter._tcp.local"
    ]

    [
      service: "_matter._tcp.local",
      instance: instance,
      port: port,
      txt: txt,
      subtypes: subtypes
    ]
  end

  @doc """
  Compute the Matter compressed fabric identifier.

  Uses HKDF-SHA256 with the 64-byte x||y coordinates of the root public key
  (stripping the 0x04 SEC1 uncompressed prefix) as IKM, the fabric ID
  (big-endian 64-bit) as salt, and "CompressedFabric" as info. Returns 8 bytes.
  """
  @spec compressed_fabric_id(binary(), non_neg_integer()) :: binary()
  def compressed_fabric_id(root_public_key, fabric_id) do
    alias MatterEx.Crypto.KDF

    # Strip the 0x04 uncompressed point prefix if present
    ikm =
      case root_public_key do
        <<0x04, xy::binary-size(64)>> -> xy
        <<xy::binary-size(64)>> -> xy
        other -> other
      end

    KDF.hkdf(<<fabric_id::unsigned-big-64>>, ikm, "CompressedFabric", 8)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(opts) do
    mdns_port = Keyword.get(opts, :port, @mdns_port)
    hostname = Keyword.get(opts, :hostname) || generate_hostname()
    interface = Keyword.get(opts, :interface)

    {addresses, dynamic_addresses} =
      case Keyword.fetch(opts, :addresses) do
        {:ok, addresses} -> {addresses, false}
        :error -> {detect_addresses(interface), true}
      end

    reuseport =
      case :os.type() do
        {:unix, :darwin} -> [{:raw, 0xFFFF, 0x0200, <<1::native-32>>}]
        {:unix, _linux} -> [{:raw, 1, 15, <<1::native-32>>}]
        _other -> []
      end

    socket_opts =
      [
        :binary,
        {:active, true},
        {:reuseaddr, true}
      ] ++ reuseport

    # Add multicast options only for the standard mDNS port
    socket_opts =
      if mdns_port == @mdns_port do
        socket_opts ++
          [
            {:multicast_ttl, 255},
            {:multicast_loop, true},
            {:add_membership, {@mdns_multicast, {0, 0, 0, 0}}}
          ]
      else
        socket_opts
      end

    case :gen_udp.open(mdns_port, socket_opts) do
      {:ok, socket} ->
        {:ok, assigned_port} = :inet.port(socket)
        socket6 = open_ipv6_socket(assigned_port, reuseport)
        join_multicast_interfaces(socket, socket6, assigned_port, addresses)
        Logger.info("mDNS responder listening on port #{assigned_port}")

        {:ok,
         %State{
           socket: socket,
           socket6: socket6,
           port: assigned_port,
           hostname: hostname,
           dynamic_addresses: dynamic_addresses,
           interface: interface,
           addresses: addresses
         }}

      {:error, reason} ->
        Logger.error("Failed to open mDNS port #{mdns_port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, state.port, state}
  end

  def handle_call({:advertise, opts}, _from, state) do
    state = refresh_network_state(state)

    service_config = %{
      service: Keyword.fetch!(opts, :service),
      instance: Keyword.fetch!(opts, :instance),
      port: Keyword.fetch!(opts, :port),
      txt: Keyword.get(opts, :txt, []),
      subtypes: Keyword.get(opts, :subtypes, [])
    }

    instance = service_config.instance
    state = %{state | services: Map.put(state.services, instance, service_config)}

    MatterEx.DebugTrace.record(%{
      type: :mdns_advertise,
      instance: instance,
      service: service_config.service,
      subtypes: service_config.subtypes,
      txt: service_config.txt,
      port: service_config.port,
      hostname: state.hostname,
      addresses: state.addresses,
      socket6: state.socket6 != nil
    })

    # Send a small announcement burst (this one plus two follow-ups ~1s apart,
    # per DNS-SD convention) so a controller reliably catches at least one after
    # a device reboot.
    send_announcement(state, service_config, @default_ttl)
    Process.send_after(self(), {:reannounce, instance}, 1000)
    Process.send_after(self(), {:reannounce, instance}, 2000)

    Logger.info("mDNS: advertising #{instance}.#{service_config.service}")
    {:reply, :ok, state}
  end

  def handle_call({:withdraw, instance}, _from, state) do
    case Map.get(state.services, instance) do
      nil ->
        {:reply, :ok, state}

      service_config ->
        # Send goodbye announcement (TTL=0)
        send_announcement(state, service_config, 0)
        state = %{state | services: Map.delete(state.services, instance)}
        MatterEx.DebugTrace.record(%{type: :mdns_withdraw, instance: instance})
        Logger.info("mDNS: withdrawn #{instance}")
        {:reply, :ok, state}
    end
  end

  def handle_call({:update_txt, instance, txt_entries}, _from, state) do
    case Map.get(state.services, instance) do
      nil ->
        {:reply, :ok, state}

      service_config ->
        service_config = %{service_config | txt: txt_entries}
        state = %{state | services: Map.put(state.services, instance, service_config)}
        # Send updated TXT record
        send_announcement(state, service_config, @default_ttl)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast(:reannounce_all, state) do
    state = refresh_network_state(state)

    Enum.each(state.services, fn {_instance, config} ->
      send_announcement(state, config, @default_ttl)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:udp, socket, ip, port, data}, state) do
    state = refresh_network_state(state)

    case DNS.decode_message(data) do
      {:ok, %{qr: :query} = msg} ->
        handle_query(state, socket, msg, ip, port)

      {:ok, _response} ->
        # Ignore responses from other responders
        :ok

      {:error, _reason} ->
        :ok
    end

    {:noreply, state}
  end

  # Follow-up announcement in the burst; also re-sent when addresses change.
  def handle_info({:reannounce, instance}, state) do
    state = refresh_network_state(state)

    case Map.get(state.services, instance) do
      nil -> :ok
      config -> send_announcement(state, config, @default_ttl)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Send goodbye for all services
    Enum.each(state.services, fn {_instance, service_config} ->
      send_announcement(state, service_config, 0)
    end)

    if state.socket do
      :gen_udp.close(state.socket)
    end

    if state.socket6 do
      :gen_udp.close(state.socket6)
    end

    :ok
  end

  # ── Private: Query Handling ─────────────────────────────────────

  defp handle_query(state, socket, msg, ip, port) do
    answers =
      Enum.flat_map(msg.questions, fn question ->
        match_question(state, question)
      end)

    MatterEx.DebugTrace.record(%{
      type: :mdns_query,
      from: format_ip(ip),
      port: port,
      questions: Enum.map(msg.questions, &Map.take(&1, [:name, :type, :class])),
      answer_count: length(answers),
      services:
        Enum.map(state.services, fn {_inst, config} ->
          config.instance <> "." <> config.service
        end)
    })

    if answers != [] do
      response = %{
        id: 0,
        qr: :response,
        aa: true,
        questions: [],
        answers: answers
      }

      {response_ip, response_port} = response_endpoint(ip, port)
      send_dns(state, socket, response, response_ip, response_port)
    end
  end

  defp format_ip(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  rescue
    _ -> inspect(ip)
  end

  defp response_endpoint(ip, _port) when tuple_size(ip) == 8, do: {@mdns_multicast6, @mdns_port}
  defp response_endpoint(ip, port), do: {ip, port}

  defp match_question(state, %{type: type, name: name}) do
    hostname_local = state.hostname <> ".local"

    cond do
      # PTR query for service type
      type in [:ptr, :any] && is_service_type_query?(state, name) ->
        build_service_records(state, name)

      # PTR query for subtype
      type in [:ptr, :any] && is_subtype_query?(state, name) ->
        build_subtype_records(state, name)

      # PTR query for service subtype suffix. Operational DNS-SD lookups query
      # `_I<compressed-fabric-id>._sub._matter._tcp.local`; answer if the
      # subtype belongs to a service we advertise even when exact subtype
      # matching is not available.
      type in [:ptr, :any] && is_subtype_suffix_query?(state, name) ->
        build_subtype_suffix_records(state, name)

      # ANY query for specific instance
      type == :any && is_instance_query?(state, name) ->
        build_srv_records(state, name) ++ build_txt_records(state, name)

      # SRV query for specific instance
      type == :srv && is_instance_query?(state, name) ->
        build_srv_records(state, name)

      # TXT query for specific instance
      type == :txt && is_instance_query?(state, name) ->
        build_txt_records(state, name)

      # A query for hostname
      type in [:a, :any] && String.downcase(name) == String.downcase(hostname_local) ->
        build_address_records(state)

      # AAAA query for hostname
      type == :aaaa && String.downcase(name) == String.downcase(hostname_local) ->
        build_address_records(state)

      true ->
        []
    end
  end

  defp is_service_type_query?(state, name) do
    Enum.any?(state.services, fn {_inst, config} ->
      String.downcase(config.service) == String.downcase(name)
    end)
  end

  defp is_subtype_query?(state, name) do
    Enum.any?(state.services, fn {_inst, config} ->
      Enum.any?(config.subtypes, fn sub ->
        String.downcase(sub) == String.downcase(name)
      end)
    end)
  end

  defp is_subtype_suffix_query?(state, name) do
    downcased_name = String.downcase(name)

    Enum.any?(state.services, fn {_inst, config} ->
      String.ends_with?(downcased_name, "._sub." <> String.downcase(config.service))
    end)
  end

  defp is_instance_query?(state, name) do
    Enum.any?(state.services, fn {_inst, config} ->
      fqn = config.instance <> "." <> config.service
      String.downcase(fqn) == String.downcase(name)
    end)
  end

  defp build_service_records(state, service_name) do
    Enum.flat_map(state.services, fn {_inst, config} ->
      if String.downcase(config.service) == String.downcase(service_name) do
        fqn = config.instance <> "." <> config.service
        hostname_local = state.hostname <> ".local"

        [
          %{name: service_name, type: :ptr, class: :in, ttl: @ptr_ttl, data: fqn},
          %{
            name: fqn,
            type: :srv,
            class: :in,
            cache_flush: true,
            ttl: @default_ttl,
            data: {0, 0, config.port, hostname_local}
          },
          %{name: fqn, type: :txt, class: :in, cache_flush: true, ttl: @ptr_ttl, data: config.txt}
        ] ++ build_address_records(state)
      else
        []
      end
    end)
  end

  defp build_subtype_records(state, subtype_name) do
    Enum.flat_map(state.services, fn {_inst, config} ->
      if Enum.any?(config.subtypes, &(String.downcase(&1) == String.downcase(subtype_name))) do
        build_subtype_answer(state, config, subtype_name)
      else
        []
      end
    end)
  end

  defp build_subtype_suffix_records(state, subtype_name) do
    downcased_name = String.downcase(subtype_name)

    Enum.flat_map(state.services, fn {_inst, config} ->
      if String.ends_with?(downcased_name, "._sub." <> String.downcase(config.service)) do
        build_subtype_answer(state, config, subtype_name)
      else
        []
      end
    end)
  end

  defp build_subtype_answer(state, config, subtype_name) do
    fqn = config.instance <> "." <> config.service
    hostname_local = state.hostname <> ".local"

    [
      %{name: subtype_name, type: :ptr, class: :in, ttl: @ptr_ttl, data: fqn},
      %{
        name: fqn,
        type: :srv,
        class: :in,
        cache_flush: true,
        ttl: @default_ttl,
        data: {0, 0, config.port, hostname_local}
      },
      %{name: fqn, type: :txt, class: :in, cache_flush: true, ttl: @ptr_ttl, data: config.txt}
    ] ++ build_address_records(state)
  end

  defp build_srv_records(state, name) do
    Enum.flat_map(state.services, fn {_inst, config} ->
      fqn = config.instance <> "." <> config.service

      if String.downcase(fqn) == String.downcase(name) do
        hostname_local = state.hostname <> ".local"

        [
          %{
            name: fqn,
            type: :srv,
            class: :in,
            cache_flush: true,
            ttl: @default_ttl,
            data: {0, 0, config.port, hostname_local}
          }
        ] ++ build_address_records(state)
      else
        []
      end
    end)
  end

  defp build_txt_records(state, name) do
    Enum.flat_map(state.services, fn {_inst, config} ->
      fqn = config.instance <> "." <> config.service

      if String.downcase(fqn) == String.downcase(name) do
        [
          %{name: fqn, type: :txt, class: :in, cache_flush: true, ttl: @ptr_ttl, data: config.txt}
        ]
      else
        []
      end
    end)
  end

  defp build_address_records(state) do
    hostname_local = state.hostname <> ".local"

    state.addresses
    |> Enum.flat_map(fn
      {_, _, _, _} = addr -> [address_record(hostname_local, :a, addr)]
      {_, _, _, _, _, _, _, _} = addr -> [address_record(hostname_local, :aaaa, addr)]
      _other -> []
    end)
  end

  defp address_record(hostname, type, addr) do
    %{
      name: hostname,
      type: type,
      class: :in,
      cache_flush: true,
      ttl: @default_ttl,
      data: addr
    }
  end

  # ── Private: Announcement ───────────────────────────────────────

  defp send_announcement(state, service_config, ttl) do
    fqn = service_config.instance <> "." <> service_config.service
    hostname_local = state.hostname <> ".local"

    records =
      [
        %{name: service_config.service, type: :ptr, class: :in, ttl: ttl, data: fqn},
        %{
          name: fqn,
          type: :srv,
          class: :in,
          cache_flush: true,
          ttl: ttl,
          data: {0, 0, service_config.port, hostname_local}
        },
        %{
          name: fqn,
          type: :txt,
          class: :in,
          cache_flush: true,
          ttl: ttl,
          data: service_config.txt
        }
      ] ++
        Enum.map(build_address_records(state), fn record -> %{record | ttl: ttl} end)

    # Add subtype PTR records
    subtype_records =
      Enum.map(service_config.subtypes, fn sub ->
        %{name: sub, type: :ptr, class: :in, ttl: ttl, data: fqn}
      end)

    response = %{
      id: 0,
      qr: :response,
      aa: true,
      questions: [],
      answers: records ++ subtype_records
    }

    # Send to multicast if on standard port, otherwise unicast not needed
    if state.port == @mdns_port do
      send_dns(state, state.socket, response, @mdns_multicast, @mdns_port)

      if state.socket6 do
        send_dns(state, state.socket6, response, @mdns_multicast6, @mdns_port)
      end
    end
  end

  # ── Private: Helpers ────────────────────────────────────────────

  defp send_dns(_state, socket, message, ip, port) do
    binary = DNS.encode_message(message)
    :gen_udp.send(socket, ip, port, binary)
  end

  defp refresh_network_state(%State{dynamic_addresses: false} = state), do: state

  defp refresh_network_state(%State{} = state) do
    addresses = detect_addresses(state.interface)
    new_addresses = addresses -- state.addresses

    if addresses != state.addresses do
      join_multicast_interfaces(state.socket, state.socket6, state.port, new_addresses)
      state = %{state | addresses: addresses}

      # A fresh address just appeared (e.g. the interface came up after boot) —
      # re-announce so controllers relearn where to reach us.
      if new_addresses != [] do
        Enum.each(state.services, fn {_instance, config} ->
          send_announcement(state, config, @default_ttl)
        end)
      end

      state
    else
      state
    end
  end

  defp open_ipv6_socket(port, reuseport) do
    bind_device = preferred_ipv6_device()

    socket_opts =
      [
        :binary,
        {:active, true},
        {:reuseaddr, true},
        :inet6,
        {:ipv6_v6only, true}
      ] ++ bind_to_device_opts(bind_device) ++ reuseport

    case :gen_udp.open(port, socket_opts) do
      {:ok, socket} ->
        socket

      {:error, reason} ->
        Logger.warning("mDNS: failed to open IPv6 socket on port #{port}: #{inspect(reason)}")
        nil
    end
  end

  defp join_multicast_interfaces(_socket, _socket6, port, _addresses) when port != @mdns_port,
    do: :ok

  defp join_multicast_interfaces(socket, socket6, _port, addresses) do
    Enum.each(addresses, fn address ->
      case address do
        {_, _, _, _} ->
          case :inet.setopts(socket, add_membership: {@mdns_multicast, address}) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.debug(
                "mDNS: could not join multicast group on #{:inet.ntoa(address)}: #{inspect(reason)}"
              )
          end

        {_, _, _, _, _, _, _, _} ->
          join_ipv6_multicast(socket6, address)

        _other ->
          :ok
      end
    end)
  end

  defp join_ipv6_multicast(nil, _address), do: :ok

  defp join_ipv6_multicast(socket, address) do
    case interface_for_address(address) do
      nil ->
        Logger.debug("mDNS: could not find interface index for #{:inet.ntoa(address)}")

      {name, ifindex} ->
        preferred = preferred_ipv6_device()

        if preferred && name != preferred do
          :ok
        else
          join_ipv6_multicast(socket, address, ifindex)
        end
    end
  end

  defp join_ipv6_multicast(socket, address, ifindex) do
    multicast_if = {:raw, @ipproto_ipv6, @ipv6_multicast_if, <<ifindex::native-32>>}
    join_group = {:raw, @ipproto_ipv6, @ipv6_join_group, ipv6_mreq(@mdns_multicast6, ifindex)}

    case :inet.setopts(socket, [multicast_if, join_group]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "mDNS: could not join IPv6 multicast group on #{:inet.ntoa(address)} ifindex=#{ifindex}: #{inspect(reason)}"
        )
    end
  end

  defp ipv6_mreq({a, b, c, d, e, f, g, h}, ifindex) do
    <<a::big-16, b::big-16, c::big-16, d::big-16, e::big-16, f::big-16, g::big-16, h::big-16,
      ifindex::native-32>>
  end

  defp interface_for_address(address) do
    with {:ok, ifaddrs} <- :inet.getifaddrs(),
         {name, _opts} <-
           Enum.find(ifaddrs, fn {_name, opts} ->
             address in Keyword.get_values(opts, :addr)
           end),
         {:ok, contents} <- File.read("/sys/class/net/#{name}/ifindex"),
         {ifindex, _} <- Integer.parse(String.trim(contents)) do
      {to_string(name), ifindex}
    else
      _ -> nil
    end
  end

  defp preferred_ipv6_device do
    if File.exists?("/sys/class/net/wlan0/ifindex"), do: "wlan0"
  end

  defp bind_to_device_opts(nil), do: []
  defp bind_to_device_opts(device), do: [{:raw, @sol_socket, @so_bindtodevice, device <> <<0>>}]

  defp generate_hostname do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "matter_ex-#{suffix}"
  end

  defp detect_addresses(interface) do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.filter(fn {name, _opts} ->
          interface_selected?(interface, to_string(name))
        end)
        |> Enum.flat_map(fn {_name, opts} ->
          Keyword.get_values(opts, :addr)
        end)
        |> Enum.filter(fn
          {127, _, _, _} -> false
          {a, _, _, _} when a >= 1 and a <= 255 -> true
          {0, 0, 0, 0, 0, 0, 0, 1} -> false
          {0, 0, 0, 0, 0, 0, 0, 0} -> false
          {_, _, _, _, _, _, _, _} -> true
          _ -> false
        end)

      {:error, _} ->
        []
    end
  end

  # `:interface` may be nil (every interface), a single name, or a list of names.
  #
  # The list form matters for a device that can be online over either Wi-Fi or
  # ethernet: pinning to one name breaks the other, while nil advertises every
  # interface — including ones a controller can't route to, such as a link-local
  # USB gadget — so it tries dead addresses first.
  defp interface_selected?(nil, _name), do: true
  defp interface_selected?(interface, name) when is_binary(interface), do: interface == name
  defp interface_selected?(interfaces, name) when is_list(interfaces), do: name in interfaces
end
