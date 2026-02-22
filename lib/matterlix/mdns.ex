defmodule Matterlix.MDNS do
  @moduledoc """
  mDNS responder GenServer for DNS-SD service discovery.

  Opens a multicast UDP socket on port 5353 (configurable), joins the
  mDNS multicast group (224.0.0.251), and responds to DNS queries for
  registered services. Sends gratuitous announcements when services
  are added or removed.

  Includes Matter-specific helpers for building commissioning discovery
  service configurations.

  ## Example

      {:ok, mdns} = Matterlix.MDNS.start_link(
        hostname: "matterlix-device",
        addresses: [{192, 168, 1, 100}]
      )

      # Advertise a Matter commissioning service
      service = Matterlix.MDNS.commissioning_service(
        port: 5540,
        discriminator: 3840,
        vendor_id: 0xFFF1,
        product_id: 0x8001,
        device_name: "Test Light"
      )

      Matterlix.MDNS.advertise(mdns, service)
  """

  use GenServer

  import Bitwise

  require Logger

  alias Matterlix.MDNS.DNS

  @mdns_port 5353
  @mdns_multicast {224, 0, 0, 251}
  @default_ttl 120
  @ptr_ttl 4500

  defmodule State do
    @moduledoc false
    defstruct [
      :socket,
      :port,
      :hostname,
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
  - `:vendor_id` — 16-bit vendor ID (required)
  - `:product_id` — 16-bit product ID (required)
  - `:device_name` — human-readable device name (optional)
  - `:device_type` — device type ID (optional)
  - `:commissioning_mode` — 1 (basic) or 2 (enhanced), default 1
  """
  @spec commissioning_service(keyword()) :: keyword()
  def commissioning_service(opts) do
    port = Keyword.fetch!(opts, :port)
    discriminator = Keyword.fetch!(opts, :discriminator)
    vendor_id = Keyword.fetch!(opts, :vendor_id)
    product_id = Keyword.fetch!(opts, :product_id)
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

    [
      service: "_matter._tcp.local",
      instance: instance,
      port: port,
      txt: txt
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
    alias Matterlix.Crypto.KDF

    # Strip the 0x04 uncompressed point prefix if present
    ikm = case root_public_key do
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
    addresses = Keyword.get(opts, :addresses) || detect_addresses()

    reuseport =
      case :os.type() do
        {:unix, :darwin} -> [{:raw, 0xFFFF, 0x0200, <<1::native-32>>}]
        {:unix, _linux}  -> [{:raw, 1, 15, <<1::native-32>>}]
        _other           -> []
      end

    socket_opts = [
      :binary,
      {:active, true},
      {:reuseaddr, true}
    ] ++ reuseport

    # Add multicast options only for the standard mDNS port
    socket_opts = if mdns_port == @mdns_port do
      socket_opts ++ [
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
        Logger.info("mDNS responder listening on port #{assigned_port}")

        {:ok, %State{
          socket: socket,
          port: assigned_port,
          hostname: hostname,
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
    service_config = %{
      service: Keyword.fetch!(opts, :service),
      instance: Keyword.fetch!(opts, :instance),
      port: Keyword.fetch!(opts, :port),
      txt: Keyword.get(opts, :txt, []),
      subtypes: Keyword.get(opts, :subtypes, [])
    }

    instance = service_config.instance
    state = %{state | services: Map.put(state.services, instance, service_config)}

    # Send gratuitous announcement
    send_announcement(state, service_config, @default_ttl)

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
  def handle_info({:udp, _socket, ip, port, data}, state) do
    case DNS.decode_message(data) do
      {:ok, %{qr: :query} = msg} ->
        handle_query(state, msg, ip, port)

      {:ok, _response} ->
        # Ignore responses from other responders
        :ok

      {:error, _reason} ->
        :ok
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

    :ok
  end

  # ── Private: Query Handling ─────────────────────────────────────

  defp handle_query(state, msg, ip, port) do
    answers = Enum.flat_map(msg.questions, fn question ->
      match_question(state, question)
    end)

    if answers != [] do
      response = %{
        id: 0,
        qr: :response,
        aa: true,
        questions: [],
        answers: answers
      }

      send_dns(state, response, ip, port)
    end
  end

  defp match_question(state, %{type: type, name: name}) do
    hostname_local = state.hostname <> ".local"

    cond do
      # PTR query for service type
      type in [:ptr, :any] && is_service_type_query?(state, name) ->
        build_service_records(state, name)

      # PTR query for subtype
      type in [:ptr, :any] && is_subtype_query?(state, name) ->
        build_subtype_records(state, name)

      # SRV query for specific instance
      type in [:srv, :any] && is_instance_query?(state, name) ->
        build_srv_records(state, name)

      # TXT query for specific instance
      type in [:txt, :any] && is_instance_query?(state, name) ->
        build_txt_records(state, name)

      # A query for hostname
      type in [:a, :any] && String.downcase(name) == String.downcase(hostname_local) ->
        build_a_records(state)

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
          %{name: fqn, type: :srv, class: :in, cache_flush: true, ttl: @default_ttl,
            data: {0, 0, config.port, hostname_local}},
          %{name: fqn, type: :txt, class: :in, cache_flush: true, ttl: @ptr_ttl,
            data: config.txt}
        ] ++ build_a_records(state)
      else
        []
      end
    end)
  end

  defp build_subtype_records(state, subtype_name) do
    Enum.flat_map(state.services, fn {_inst, config} ->
      if Enum.any?(config.subtypes, &(String.downcase(&1) == String.downcase(subtype_name))) do
        fqn = config.instance <> "." <> config.service
        hostname_local = state.hostname <> ".local"

        [
          %{name: subtype_name, type: :ptr, class: :in, ttl: @ptr_ttl, data: fqn},
          %{name: fqn, type: :srv, class: :in, cache_flush: true, ttl: @default_ttl,
            data: {0, 0, config.port, hostname_local}},
          %{name: fqn, type: :txt, class: :in, cache_flush: true, ttl: @ptr_ttl,
            data: config.txt}
        ] ++ build_a_records(state)
      else
        []
      end
    end)
  end

  defp build_srv_records(state, name) do
    Enum.flat_map(state.services, fn {_inst, config} ->
      fqn = config.instance <> "." <> config.service
      if String.downcase(fqn) == String.downcase(name) do
        hostname_local = state.hostname <> ".local"

        [
          %{name: fqn, type: :srv, class: :in, cache_flush: true, ttl: @default_ttl,
            data: {0, 0, config.port, hostname_local}}
        ] ++ build_a_records(state)
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
          %{name: fqn, type: :txt, class: :in, cache_flush: true, ttl: @ptr_ttl,
            data: config.txt}
        ]
      else
        []
      end
    end)
  end

  defp build_a_records(state) do
    hostname_local = state.hostname <> ".local"

    Enum.map(state.addresses, fn addr ->
      %{name: hostname_local, type: :a, class: :in, cache_flush: true,
        ttl: @default_ttl, data: addr}
    end)
  end

  # ── Private: Announcement ───────────────────────────────────────

  defp send_announcement(state, service_config, ttl) do
    fqn = service_config.instance <> "." <> service_config.service
    hostname_local = state.hostname <> ".local"

    records = [
      %{name: service_config.service, type: :ptr, class: :in, ttl: ttl, data: fqn},
      %{name: fqn, type: :srv, class: :in, cache_flush: true, ttl: ttl,
        data: {0, 0, service_config.port, hostname_local}},
      %{name: fqn, type: :txt, class: :in, cache_flush: true, ttl: ttl,
        data: service_config.txt}
    ] ++ Enum.map(state.addresses, fn addr ->
      %{name: hostname_local, type: :a, class: :in, cache_flush: true, ttl: ttl, data: addr}
    end)

    # Add subtype PTR records
    subtype_records = Enum.map(service_config.subtypes, fn sub ->
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
      send_dns(state, response, @mdns_multicast, @mdns_port)
    end
  end

  # ── Private: Helpers ────────────────────────────────────────────

  defp send_dns(state, message, ip, port) do
    binary = DNS.encode_message(message)
    :gen_udp.send(state.socket, ip, port, binary)
  end

  defp generate_hostname do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "matterlix-#{suffix}"
  end

  defp detect_addresses do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.flat_map(fn {_name, opts} ->
          Keyword.get_values(opts, :addr)
        end)
        |> Enum.filter(fn
          {127, _, _, _} -> false
          {a, _, _, _} when a >= 1 and a <= 255 -> true
          _ -> false
        end)

      {:error, _} ->
        []
    end
  end
end
