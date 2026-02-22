# Elixir-First Matter Stack

A pure Elixir implementation of the Matter (CHIP) smart home protocol, replacing the C++ SDK with native Elixir code. Designed for embedded Linux (Nerves) and general Elixir/Erlang systems.

## Motivation

The current matter_ex wraps the C++ Matter SDK via NIFs. This works, but:

- **Elixir is a second-class citizen** — the C++ SDK controls everything (BLE, commissioning, data model, sessions). Elixir only gets thin callbacks.
- **BlueZ/D-Bus dependency** — BLE commissioning requires a custom Nerves system with kernel Bluetooth drivers, BlueZ, and D-Bus. This is the #1 barrier for new users.
- **NIF risks** — a crash in the C++ code takes down the entire BEAM VM. No OTP supervision, no graceful recovery.
- **Inflexible data model** — clusters and attributes are defined in C++ (ZAP-generated). Adding a new cluster requires rebuilding the SDK.
- **Build complexity** — cross-compiling the Matter SDK (225MB libCHIP.a, 111 object files, 43 static libraries) is fragile and slow.

## Decisions

1. **Mono-repo** — single `matter_ex` hex package with clear module boundaries (not umbrella)
2. **Name** — `matter_ex` (same package, major version bump for the rewrite)
3. **Replaces current project** — the C++ NIF approach is superseded by native Elixir
4. **First device type** — On/Off Light, but the cluster system must make adding new types trivial (declarative macros, ~10-20 lines per cluster)
5. **blue_heron viability** — needs prototyping for GATT server role in Phase 2

## What This Gives Us

- **OTP supervision** for every layer (BLE, sessions, endpoints)
- **No C++ dependency** for the core protocol (only optional NIFs for crypto acceleration)
- **No BlueZ/D-Bus** — BLE via direct HCI access (like blue_heron)
- **No custom Nerves system** needed for Bluetooth
- **Hot code reload** of device profiles and cluster definitions
- **Pattern matching** for protocol parsing (Matter TLV is a binary format — ideal for Elixir)
- **Testability** — every layer independently testable in ExUnit, no hardware needed

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Your Application                         │
│                                                             │
│   use MatterEx.Cluster.OnOff                                  │
│   use MatterEx.Cluster.LevelControl                           │
│   def handle_on(_ctx), do: GPIO.write(pin, 1)              │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   MatterEx.Device  — supervision tree for a Matter device     │
│   ├── MatterEx.Endpoint (per endpoint, e.g. endpoint 1)       │
│   │   ├── MatterEx.Cluster.OnOff (GenServer)                  │
│   │   ├── MatterEx.Cluster.LevelControl (GenServer)           │
│   │   └── ...                                               │
│   ├── MatterEx.SessionManager (active sessions)               │
│   ├── MatterEx.SubscriptionManager (active subscriptions)     │
│   └── MatterEx.CommissioningManager (state machine)           │
│                                                             │
├──────────────── Interaction Model ──────────────────────────┤
│                                                             │
│   MatterEx.IM  — Read, Write, Subscribe, Invoke, Report       │
│   Encodes/decodes IM messages, routes to clusters            │
│                                                             │
├──────────────── Security ────────────────────────────────────┤
│                                                             │
│   MatterEx.Crypto.PASE  — SPAKE2+ (commissioning)           │
│   MatterEx.Crypto.CASE  — Certificate-based (operational)   │
│   MatterEx.Crypto.Session — Encrypt/decrypt/verify           │
│   Uses Erlang :crypto (P-256, AES-CCM, HKDF, HMAC)         │
│                                                             │
├──────────────── Message Layer ───────────────────────────────┤
│                                                             │
│   MatterEx.Protocol.MRP  — Message Reliability Protocol       │
│   MatterEx.Protocol.MessageCodec — Frame encode/decode         │
│   MatterEx.Protocol.Exchange — Request/response tracking       │
│   UDP for operational, BLE for commissioning                 │
│                                                             │
├──────────────── Transport ───────────────────────────────────┤
│                                                             │
│   MatterEx.Transport.BLE   — CHIPoBLE via HCI (blue_heron)    │
│   MatterEx.Transport.UDP   — gen_udp, port 5540               │
│   MatterEx.Transport.MDNS  — mdns_lite for discovery          │
│                                                             │
├──────────────── Encoding ────────────────────────────────────┤
│                                                             │
│   MatterEx.TLV  — Tag-Length-Value binary codec             │
│   Pure Elixir, zero dependencies                             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Phase 1: TLV Encoder/Decoder (`matter_tlv`)

**Goal**: Pure Elixir implementation of Matter TLV (Tag-Length-Value) encoding.

**Why first**: TLV is the serialization format used everywhere in Matter — messages, attributes, commands, commissioning payloads. Every other layer depends on it. It's also self-contained and easy to test against the spec.

### Matter TLV Format

Matter TLV is a compact binary format defined in the Matter spec (Appendix A). Each element consists of:

```
┌──────────┬──────────┬───────┐
│ Control  │ Tag      │ Value │
│ (1 byte) │ (0-8 B)  │ (var) │
└──────────┴──────────┴───────┘
```

Control byte encodes:
- Bits 0-4: Element type (Signed Int, Unsigned Int, Bool, Float, UTF8 String, Byte String, Null, Struct, Array, List, End of Container)
- Bits 5-7: Tag form (Anonymous, Context-specific 1-byte, Common Profile 2-byte, Common Profile 4-byte, Implicit Profile 2-byte, Implicit Profile 4-byte, Fully Qualified 6-byte, Fully Qualified 8-byte)

### Elixir API Design

```elixir
# Encoding
MatterEx.TLV.encode(%{
  1 => {:uint, 42},
  2 => {:string, "hello"},
  3 => {:struct, %{
    0 => {:bool, true},
    1 => {:bytes, <<0xDE, 0xAD>>}
  }}
})
# => <<...binary...>>

# Decoding
MatterEx.TLV.decode(<<...binary...>>)
# => %{1 => 42, 2 => "hello", 3 => %{0 => true, 1 => <<0xDE, 0xAD>>}}

# Streaming decode (for large payloads)
MatterEx.TLV.decode_stream(binary, fn element, acc -> ... end, initial_acc)
```

### Implementation

Pattern matching on the control byte:

```elixir
defmodule MatterEx.TLV do
  # Signed integers
  def decode_element(<<control, rest::binary>>) do
    {tag, rest} = decode_tag(control, rest)
    {value, rest} = decode_value(control, rest)
    {%Element{tag: tag, value: value}, rest}
  end

  defp decode_value(control, <<value::signed-little-8, rest::binary>>)
    when element_type(control) == :int8, do: {value, rest}

  defp decode_value(control, <<value::signed-little-16, rest::binary>>)
    when element_type(control) == :int16, do: {value, rest}

  # ... etc for all types
end
```

### Testing

- Encode → decode roundtrip property testing (StreamData)
- Test vectors from Matter SDK test suite (`src/lib/core/tests/TestCHIPTLV.cpp`)
- Fuzzing with random binaries to verify decoder doesn't crash

### Deliverable

Module `MatterEx.TLV` — zero external dependencies.

**Estimated effort**: 2-3 weeks.

---

## Phase 2: BLE Transport (`matter_ble`)

**Goal**: Implement Matter's BLE commissioning transport (CHIPoBLE) in pure Elixir, eliminating the BlueZ/D-Bus dependency.

**Why second**: This solves the #1 user pain point — no more custom Nerves systems for Bluetooth. And BLE is only needed during commissioning (not operational communication), so the scope is bounded.

### How Matter Uses BLE

Matter uses BLE only for the initial commissioning flow:

1. Device advertises a specific BLE service (CHIPoBLE)
2. Commissioner (phone/hub) connects via BLE
3. PASE handshake happens over BLE (passcode verification)
4. Commissioner sends WiFi/Thread credentials over the secure BLE channel
5. Device connects to the network
6. BLE connection is dropped — all further communication is IP-based

### CHIPoBLE GATT Service

```
Service UUID: 0xFFF6 (Matter/CHIP)
├── TX Characteristic (device → commissioner)
│   UUID: 18EE2EF5-263D-4559-959F-4F9C429F9D11
│   Properties: Indicate
├── RX Characteristic (commissioner → device)
│   UUID: 18EE2EF5-263D-4559-959F-4F9C429F9D12
│   Properties: Write
└── Additional Data Characteristic (optional)
    UUID: 64630238-8772-45F2-B87D-748A83218F04
    Properties: Read
```

BLE packets are fragmented using BTP (BLE Transport Protocol):
- Max fragment size based on negotiated MTU
- Sequence numbers for ordering
- Ack mechanism for flow control

### BLE Stack Options

**Option A: blue_heron (preferred starting point)**
- Pure Elixir BLE stack
- Talks directly to HCI (bypasses BlueZ entirely)
- Supports GATT server role
- Works on BCM43438 (RPi Zero W, RPi 3B) via HCI UART
- Experimental but actively maintained
- Repository: https://github.com/blue-heron/blue_heron

**Option B: Custom HCI implementation**
- Write minimal HCI commands directly
- Only implement what Matter needs (advertising, GATT server, one connection)
- More control, less dependency risk
- Could be a fork/subset of blue_heron

**Option C: BLE via Linux HCI socket (no BlueZ, but needs kernel BT)**
- Use raw HCI sockets from Elixir (`:gen_tcp` style)
- Still needs kernel CONFIG_BT but NOT BlueZ/D-Bus
- More portable than blue_heron's transport-specific code

### Elixir API Design

```elixir
# Start BLE commissioning advertisement
{:ok, ble} = MatterEx.Transport.BLE.start_link(
  discriminator: 3840,
  vendor_id: 0xFFF1,
  product_id: 0x8001
)

# BLE advertises automatically, waits for connection
# When a commissioner connects, we get a transport stream:
#   {:ble_connected, transport_pid}
#   {:ble_data, transport_pid, data}
#   {:ble_disconnected, transport_pid}

# Send data back (fragmented automatically via BTP)
MatterEx.Transport.BLE.send(transport_pid, response_data)

# Stop advertising
MatterEx.Transport.BLE.stop_advertising(ble)
```

### BTP (BLE Transport Protocol) Implementation

```elixir
defmodule MatterEx.Transport.BTP do
  @moduledoc "BLE Transport Protocol - fragmentation and reassembly"

  defstruct [
    :mtu,             # Negotiated MTU (default 247)
    :tx_seq,          # Outgoing sequence number
    :rx_seq,          # Expected incoming sequence number
    :rx_buffer,       # Reassembly buffer for incoming fragments
    :tx_queue,        # Outgoing fragment queue
    :ack_pending      # Whether we owe an ack
  ]

  # Fragment a message into BTP packets
  def fragment(message, mtu) do
    payload_size = mtu - 2  # BTP header overhead
    chunks = for <<chunk::binary-size(payload_size) <- message>>, do: chunk
    # Add sequence numbers, begin/end flags
    ...
  end

  # Reassemble fragments into complete message
  def reassemble(state, fragment) do
    # Validate sequence number, buffer fragment, check if complete
    ...
  end
end
```

### Testing

- BTP fragmentation/reassembly: property tests with random payloads and MTU sizes
- GATT service advertisement: verify correct UUIDs and characteristics
- Integration test with chip-tool BLE scanning (on real hardware)
- Mock BLE transport for unit testing upper layers

### Deliverable

Module `MatterEx.Transport.BLE` — uses `MatterEx.TLV` and optionally `blue_heron`.

**Estimated effort**: 4-6 weeks.

---

## Phase 3: Cryptography (`matter_crypto`)

**Goal**: Implement Matter's cryptographic operations using Erlang's `:crypto` module.

### What Matter Needs

| Operation | Used For | Erlang :crypto Support |
|-----------|----------|----------------------|
| SPAKE2+ (P-256) | PASE commissioning (passcode verification) | EC operations: yes. SPAKE2+ algorithm: implement ourselves |
| ECDSA (P-256) | CASE authentication (certificate signing) | `:crypto.sign/4` — fully supported |
| ECDH (P-256) | Key agreement | `:crypto.compute_key/4` — fully supported |
| AES-128-CCM | Message encryption | `:crypto.crypto_one_time_aead/6` — fully supported |
| HKDF-SHA256 | Key derivation | Not built-in, but trivial to implement with `:crypto.mac/4` |
| HMAC-SHA256 | Message authentication | `:crypto.mac/4` — fully supported |
| SHA-256 | Hashing | `:crypto.hash/2` — fully supported |
| PBKDF2 | Passcode to SPAKE2+ verifier | Implement with `:crypto.mac/4` |
| X.509 | Device Attestation Certificates | `:public_key` module — fully supported |

### SPAKE2+ Implementation

SPAKE2+ is the core of PASE (Passcode-Authenticated Session Establishment). It lets two parties prove they know the same passcode without revealing it.

```elixir
defmodule MatterEx.Crypto.SPAKE2Plus do
  @moduledoc """
  SPAKE2+ implementation for Matter PASE commissioning.

  Uses P-256 curve with Matter-specific M and N points.
  """

  # Matter-specific generator points (from spec)
  @m_point <<0x04, 0x88, ...>>  # Defined in Matter spec section 3.10
  @n_point <<0x04, 0xD8, ...>>

  @type verifier :: %{w0: binary(), l: binary()}
  @type context :: %{
    my_key: binary(),
    peer_key: binary(),
    shared_secret: binary(),
    transcript: binary()
  }

  @doc "Generate SPAKE2+ verifier from passcode (done once, stored on device)"
  @spec compute_verifier(passcode :: integer(), salt :: binary(), iterations :: integer()) :: verifier()
  def compute_verifier(passcode, salt, iterations) do
    # 1. PBKDF2 to derive w0 and w1
    ws = pbkdf2(Integer.to_string(passcode), salt, iterations, 80)
    w0 = binary_part(ws, 0, 40) |> mod_order()
    w1 = binary_part(ws, 40, 40) |> mod_order()

    # 2. L = w1 * G (generator point)
    l = ec_multiply(w1, generator_point())

    %{w0: w0, l: l}
  end

  @doc "Prover side (commissioner): generate pA"
  def prover_start(w0) do
    {x, x_pub} = generate_keypair()
    # pA = x * G + w0 * M
    pa = ec_add(x_pub, ec_multiply(w0, @m_point))
    {pa, %{x: x, w0: w0}}
  end

  @doc "Verifier side (device): generate pB, compute shared secret"
  def verifier_respond(pa, verifier) do
    {y, y_pub} = generate_keypair()
    # pB = y * G + w0 * N
    pb = ec_add(y_pub, ec_multiply(verifier.w0, @n_point))

    # Shared secret: Z = y * (pA - w0 * M)
    z = ec_multiply(y, ec_add(pa, ec_negate(ec_multiply(verifier.w0, @m_point))))
    # V = y * L
    v = ec_multiply(y, verifier.l)

    {pb, derive_keys(pa, pb, z, v, verifier.w0)}
  end

  # ... key confirmation (cA, cB MAC exchange)
end
```

### Session Encryption

Once PASE or CASE establishes a session, all messages are encrypted with AES-128-CCM:

```elixir
defmodule MatterEx.Crypto.Session do
  @doc "Encrypt a message for a session"
  def encrypt(plaintext, session_key, nonce, aad) do
    :crypto.crypto_one_time_aead(:aes_128_ccm, session_key, nonce, plaintext, aad, 16, true)
  end

  @doc "Decrypt a message from a session"
  def decrypt(ciphertext, tag, session_key, nonce, aad) do
    :crypto.crypto_one_time_aead(:aes_128_ccm, session_key, nonce, ciphertext, aad, 16, false)
  end
end
```

### Testing

- SPAKE2+ test vectors from the Matter SDK (`src/crypto/tests/CHIPCryptoPALTest.cpp`)
- RFC 9383 (SPAKE2+) test vectors
- AES-CCM test vectors from NIST
- Full PASE handshake simulation (prover + verifier in same test)

### Deliverable

Module `MatterEx.Crypto.*` — depends on Erlang `:crypto` (ships with OTP). No C++ NIFs needed.

**Estimated effort**: 3-4 weeks.

---

## Phase 4: Message Layer (`matter_protocol`)

**Goal**: Implement Matter's message framing, reliability protocol (MRP), and exchange management.

### Message Frame Format

Every Matter message has this structure:

```
┌─────────────────────────────────────────────────┐
│ Message Header                                   │
│ ├── Flags (1 byte)                               │
│ ├── Session ID (2 bytes)                         │
│ ├── Security Flags (1 byte)                      │
│ ├── Message Counter (4 bytes)                    │
│ ├── Source Node ID (0 or 8 bytes, optional)      │
│ └── Dest Node ID (0 or 8 bytes, optional)        │
├─────────────────────────────────────────────────┤
│ Protocol Header                                  │
│ ├── Exchange Flags (1 byte)                      │
│ ├── Protocol Opcode (1 byte)                     │
│ ├── Exchange ID (2 bytes)                        │
│ ├── Protocol ID (2 bytes)                        │
│ └── Ack Counter (0 or 4 bytes, optional)         │
├─────────────────────────────────────────────────┤
│ Payload (TLV-encoded)                            │
├─────────────────────────────────────────────────┤
│ Message Integrity Check (variable, encrypted)    │
└─────────────────────────────────────────────────┘
```

### MRP (Message Reliability Protocol)

MRP provides reliable delivery over UDP (which is unreliable):

```elixir
defmodule MatterEx.Protocol.MRP do
  @moduledoc """
  Message Reliability Protocol.

  Handles retransmission with exponential backoff.
  Default timeouts from Matter spec:
  - MRP_RETRY_INTERVAL_IDLE: 500ms
  - MRP_RETRY_INTERVAL_ACTIVE: 300ms
  - MRP_BACKOFF_BASE: 1.6
  - MRP_BACKOFF_JITTER: 0.25
  - MRP_BACKOFF_MARGIN: 1.1
  - MRP_MAX_TRANSMISSIONS: 5 (initial + 4 retries)
  """

  use GenServer

  defstruct [
    :transport,          # BLE or UDP transport pid
    :pending_acks,       # Messages waiting for acknowledgment
    :message_counter,    # Monotonically increasing counter
    :peer_counters       # Track peer message counters (replay protection)
  ]

  def send_reliable(mrp, message) do
    GenServer.call(mrp, {:send_reliable, message})
  end

  # Retransmission timer fires
  def handle_info({:retransmit, exchange_id, attempt}, state) do
    case Map.get(state.pending_acks, exchange_id) do
      nil -> {:noreply, state}  # Already acked
      pending when attempt >= @max_transmissions ->
        # Give up
        notify_failure(pending.caller, :timeout)
        {:noreply, remove_pending(state, exchange_id)}
      pending ->
        # Retransmit with backoff
        resend(state.transport, pending.message)
        interval = calculate_backoff(attempt)
        Process.send_after(self(), {:retransmit, exchange_id, attempt + 1}, interval)
        {:noreply, state}
    end
  end
end
```

### Exchange Manager

An "exchange" is a request-response pair (like an HTTP transaction):

```elixir
defmodule MatterEx.Protocol.ExchangeManager do
  @moduledoc """
  Manages active exchanges (request/response pairs).

  Each exchange has:
  - Unique exchange ID
  - Associated session
  - Protocol handler (IM, PASE, CASE, etc.)
  - Timeout
  """

  use GenServer

  def initiate_exchange(manager, session, protocol) do
    GenServer.call(manager, {:initiate, session, protocol})
  end

  # Incoming message — route to the right exchange or create new one
  def handle_message(manager, message) do
    GenServer.cast(manager, {:incoming, message})
  end
end
```

### Testing

- Message encode/decode roundtrip tests
- MRP retransmission timing tests (with mocked timers)
- Exchange lifecycle tests
- Message counter replay protection tests
- Interop: decode real Matter messages captured from chip-tool

### Deliverable

Module `MatterEx.Protocol.*` — uses `MatterEx.TLV` and `MatterEx.Crypto`.

**Estimated effort**: 3-4 weeks.

---

## Phase 5: Interaction Model (`matter_im`)

**Goal**: Implement Matter's Interaction Model — the application-layer protocol for reading attributes, writing values, subscribing to changes, and invoking commands.

### Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| Read | Read attribute values | "What's the current brightness?" |
| Write | Set attribute values | "Set brightness to 50%" |
| Subscribe | Get notified on changes | "Tell me when on/off changes" |
| Invoke | Execute a command | "Toggle the light" |
| Report | Push attribute values | Device reports a sensor reading |

### Elixir API

```elixir
defmodule MatterEx.IM do
  @moduledoc """
  Interaction Model message handling.

  Routes incoming IM requests to the appropriate cluster handlers
  and formats responses.
  """

  # Handle incoming Read Request
  def handle_read_request(request, device) do
    results = Enum.map(request.attribute_paths, fn path ->
      case MatterEx.Device.read_attribute(device, path) do
        {:ok, value} -> %{path: path, value: value, status: :success}
        {:error, status} -> %{path: path, status: status}
      end
    end)
    encode_report_data(results)
  end

  # Handle incoming Write Request
  def handle_write_request(request, device) do
    results = Enum.map(request.write_requests, fn write ->
      MatterEx.Device.write_attribute(device, write.path, write.value)
    end)
    encode_write_response(results)
  end

  # Handle incoming Invoke Request
  def handle_invoke_request(request, device) do
    results = Enum.map(request.invoke_requests, fn invoke ->
      MatterEx.Device.invoke_command(device, invoke.path, invoke.fields)
    end)
    encode_invoke_response(results)
  end
end
```

### Subscription Manager

```elixir
defmodule MatterEx.IM.SubscriptionManager do
  @moduledoc """
  Manages active subscriptions from controllers.

  When an attribute changes, notifies all subscribers via Report messages.
  Uses Elixir Registry for efficient pub/sub routing.
  """

  use GenServer

  def subscribe(manager, subscriber_session, paths, min_interval, max_interval) do
    # Register interest in specific attribute paths
    # Start periodic reporting timer
    # Send initial report with current values
  end

  # Called when any attribute changes
  def handle_info({:attribute_changed, endpoint, cluster, attribute, value}, state) do
    # Find all subscriptions that match this path
    # Send Report Data to each subscriber
  end
end
```

### Testing

- Read/Write/Subscribe/Invoke request encoding/decoding
- Subscription lifecycle (create, report, teardown)
- Timed interactions (min/max interval enforcement)
- Status code handling (unsupported attribute, cluster, etc.)

### Deliverable

Module `MatterEx.IM.*` — uses `MatterEx.TLV` and `MatterEx.Protocol`.

**Estimated effort**: 4-6 weeks.

---

## Phase 6: Data Model Framework

**Goal**: Define Matter device types, endpoints, and clusters as Elixir behaviours and supervised processes. This is where the developer-facing API lives.

**Key requirement**: Adding a new cluster type must be trivially easy — a single module with declarative macros.

### Developer Experience — Device Definition

```elixir
defmodule MyApp.Light do
  use MatterEx.Device,
    vendor_name: "My Company",
    product_name: "Smart Light",
    vendor_id: 0xFFF1,
    product_id: 0x8001

  # Endpoint 1: a dimmable light
  endpoint 1 do
    cluster MatterEx.Cluster.OnOff
    cluster MatterEx.Cluster.LevelControl
  end

  # React to attribute changes (optional — only implement what you need)
  def handle_attribute_change(1, :on_off, :on_off, true), do: MyApp.GPIO.write(@led_pin, 1)
  def handle_attribute_change(1, :on_off, :on_off, false), do: MyApp.GPIO.write(@led_pin, 0)
  def handle_attribute_change(1, :level_control, :current_level, level) do
    MyApp.PWM.set_duty_cycle(@led_pin, level / 254)
  end
  def handle_attribute_change(_, _, _, _), do: :ok
end
```

The `use MatterEx.Device` macro:
- Auto-generates endpoint 0 (root) with Descriptor + BasicInformation clusters
- Creates a supervision tree with all endpoints and clusters as children
- Provides `start_link/1` and `child_spec/1` for use in your app's supervisor
- Wires up attribute change notifications to your `handle_attribute_change/4` callback

### Cluster Macro System — The Core Design

This is the most important API decision. Adding a new cluster must be **one module, ~20-50 lines**:

```elixir
defmodule MatterEx.Cluster.OnOff do
  use MatterEx.Cluster, id: 0x0006, name: :on_off

  # Attributes — declarative, type-safe
  attribute 0x0000, :on_off,      :boolean, default: false, writable: true
  attribute 0x4000, :global_scene_control, :boolean, default: true
  attribute 0x4001, :on_time,     :uint16,  default: 0, writable: true
  attribute 0x4002, :off_wait_time, :uint16, default: 0, writable: true
  attribute 0xFFFD, :cluster_revision, :uint16, default: 4

  # Commands — name, id, and parameter specs
  command 0x00, :off, []
  command 0x01, :on, []
  command 0x02, :toggle, []
  command 0x40, :off_with_effect, [effect_identifier: :uint8, effect_variant: :uint8]
  command 0x41, :on_with_recall_global_scene, []
  command 0x42, :on_with_timed_off, [on_off_control: :uint8, on_time: :uint16, off_wait_time: :uint16]

  # Command handlers — pattern match on command name
  @impl true
  def handle_command(:off, _params, state) do
    {:ok, set_attribute(state, :on_off, false)}
  end

  def handle_command(:on, _params, state) do
    {:ok, set_attribute(state, :on_off, true)}
  end

  def handle_command(:toggle, _params, state) do
    {:ok, set_attribute(state, :on_off, !get_attribute(state, :on_off))}
  end
end
```

### What `use MatterEx.Cluster` Generates

The macro provides:
- A GenServer that holds attribute state
- `get_attribute/2`, `set_attribute/3` helpers that auto-notify subscribers
- `handle_read/2`, `handle_write/3` default implementations based on attribute definitions
- Attribute metadata (type, default, writable) used by the IM layer for validation
- TLV encoding hints from the type declarations

```elixir
defmodule MatterEx.Cluster do
  @type attribute_def :: %{
    id: non_neg_integer(),
    name: atom(),
    type: :boolean | :uint8 | :uint16 | :uint32 | :int8 | :int16 | :int32 |
          :string | :bytes | :float | :double | :enum8 | :bitmap8 | :bitmap16,
    default: term(),
    writable: boolean()
  }

  @type command_def :: %{
    id: non_neg_integer(),
    name: atom(),
    params: keyword()   # [{param_name, type}]
  }

  @callback cluster_id() :: non_neg_integer()
  @callback cluster_name() :: atom()
  @callback attribute_defs() :: [attribute_def()]
  @callback command_defs() :: [command_def()]
  @callback handle_command(name :: atom(), params :: map(), state :: map()) ::
    {:ok, state :: map()} | {:error, atom()}

  defmacro __using__(opts) do
    quote do
      @behaviour MatterEx.Cluster
      use GenServer
      import MatterEx.Cluster, only: [attribute: 4, attribute: 3, command: 3]

      Module.register_attribute(__MODULE__, :matter_attributes, accumulate: true)
      Module.register_attribute(__MODULE__, :matter_commands, accumulate: true)

      @cluster_id unquote(opts[:id])
      @cluster_name unquote(opts[:name])

      @before_compile MatterEx.Cluster

      # GenServer API
      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

      def get_attribute(state, name), do: Map.get(state, name)

      def set_attribute(state, name, value) do
        # Notify subscribers via Registry
        MatterEx.AttributeRegistry.notify(
          self(), @cluster_name, name, value
        )
        Map.put(state, name, value)
      end

      def init(opts) do
        # Build initial state from attribute defaults
        state = Enum.reduce(@matter_attributes, %{}, fn attr, acc ->
          Map.put(acc, attr.name, attr.default)
        end)
        {:ok, state}
      end

      # Default handle_call for reads
      def handle_call({:read_attribute, name}, _from, state) do
        {:reply, {:ok, Map.get(state, name)}, state}
      end

      # Default handle_call for writes
      def handle_call({:write_attribute, name, value}, _from, state) do
        attr = Enum.find(@matter_attributes, &(&1.name == name))
        cond do
          attr == nil -> {:reply, {:error, :unsupported_attribute}, state}
          !attr.writable -> {:reply, {:error, :read_only}, state}
          true -> {:reply, :ok, set_attribute(state, name, value)}
        end
      end

      # Default handle_call for commands
      def handle_call({:invoke_command, name, params}, _from, state) do
        case handle_command(name, params, state) do
          {:ok, new_state} -> {:reply, :ok, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
      end

      defoverridable [init: 1, handle_command: 3]
    end
  end

  # Compile-time: generate cluster_id/0, attribute_defs/0, etc.
  defmacro __before_compile__(env) do
    attributes = Module.get_attribute(env.module, :matter_attributes) |> Enum.reverse()
    commands = Module.get_attribute(env.module, :matter_commands) |> Enum.reverse()

    quote do
      @impl MatterEx.Cluster
      def cluster_id, do: @cluster_id

      @impl MatterEx.Cluster
      def cluster_name, do: @cluster_name

      @impl MatterEx.Cluster
      def attribute_defs, do: unquote(Macro.escape(attributes))

      @impl MatterEx.Cluster
      def command_defs, do: unquote(Macro.escape(commands))
    end
  end

  # DSL macros
  defmacro attribute(id, name, type, opts \\ []) do
    quote do
      @matter_attributes %{
        id: unquote(id),
        name: unquote(name),
        type: unquote(type),
        default: unquote(Keyword.get(opts, :default)),
        writable: unquote(Keyword.get(opts, :writable, false))
      }
    end
  end

  defmacro command(id, name, params) do
    quote do
      @matter_commands %{
        id: unquote(id),
        name: unquote(name),
        params: unquote(params)
      }
    end
  end
end
```

### Adding a New Cluster — Example: Temperature Measurement

This is how easy it is to add a completely new cluster type:

```elixir
defmodule MatterEx.Cluster.TemperatureMeasurement do
  use MatterEx.Cluster, id: 0x0402, name: :temperature_measurement

  # All attributes from the Matter spec for this cluster
  attribute 0x0000, :measured_value,    :int16,  default: nil    # nil = unknown
  attribute 0x0001, :min_measured_value, :int16,  default: -2732  # -273.2°C
  attribute 0x0002, :max_measured_value, :int16,  default: 32767  # 327.67°C
  attribute 0x0003, :tolerance,         :uint16, default: 0
  attribute 0xFFFD, :cluster_revision,  :uint16, default: 4

  # No commands — this is a read-only sensor cluster
  # The device pushes values via:
  #   GenServer.call(cluster_pid, {:write_attribute, :measured_value, 2350})
  # Which represents 23.50°C (value is in 0.01°C units)
end
```

That's it. **13 lines** for a complete cluster. The macro system handles:
- GenServer lifecycle
- Attribute storage and defaults
- Read/write validation (type checking, writable flag)
- Subscriber notifications on change
- TLV encoding metadata
- IM layer integration

### More Examples — How Easy It Is

**Door Lock:**
```elixir
defmodule MatterEx.Cluster.DoorLock do
  use MatterEx.Cluster, id: 0x0101, name: :door_lock

  attribute 0x0000, :lock_state,   :enum8,  default: 1  # 0=not_locked, 1=locked, 2=unlocked
  attribute 0x0001, :lock_type,    :enum8,  default: 0
  attribute 0x0002, :actuator_enabled, :boolean, default: true
  attribute 0xFFFD, :cluster_revision, :uint16, default: 6

  command 0x00, :lock_door, [pin_code: :bytes]
  command 0x01, :unlock_door, [pin_code: :bytes]

  @impl true
  def handle_command(:lock_door, _params, state) do
    {:ok, set_attribute(state, :lock_state, 1)}
  end

  def handle_command(:unlock_door, _params, state) do
    {:ok, set_attribute(state, :lock_state, 2)}
  end
end
```

**Boolean State (contact sensor):**
```elixir
defmodule MatterEx.Cluster.BooleanState do
  use MatterEx.Cluster, id: 0x0045, name: :boolean_state

  attribute 0x0000, :state_value, :boolean, default: false
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  # No commands — state is set by the device hardware
end
```

**7 lines.** That's a complete Matter-compliant cluster.

### Device Macro — Wiring It All Together

```elixir
defmodule MatterEx.Device do
  defmacro __using__(opts) do
    quote do
      import MatterEx.Device, only: [endpoint: 2]
      Module.register_attribute(__MODULE__, :matter_endpoints, accumulate: true)

      @device_opts unquote(opts)
      @before_compile MatterEx.Device
    end
  end

  defmacro endpoint(id, do: block) do
    quote do
      @current_endpoint unquote(id)
      Module.register_attribute(__MODULE__, :current_endpoint_clusters, accumulate: true)
      unquote(block)
      @matter_endpoints {
        unquote(id),
        Module.get_attribute(__MODULE__, :current_endpoint_clusters) |> Enum.reverse()
      }
      Module.delete_attribute(__MODULE__, :current_endpoint_clusters)
    end
  end

  # Inside endpoint block, `cluster` registers a cluster module
  defmacro cluster(module, opts \\ []) do
    quote do
      @current_endpoint_clusters {unquote(module), unquote(opts)}
    end
  end

  defmacro __before_compile__(env) do
    endpoints = Module.get_attribute(env.module, :matter_endpoints) |> Enum.reverse()

    quote do
      use Supervisor

      def start_link(opts \\ []) do
        Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def init(opts) do
        children = build_endpoint_children(unquote(Macro.escape(endpoints)), opts)
        Supervisor.init(children, strategy: :one_for_one)
      end

      defp build_endpoint_children(endpoints, _opts) do
        Enum.flat_map(endpoints, fn {endpoint_id, clusters} ->
          Enum.map(clusters, fn {cluster_module, cluster_opts} ->
            name = :"#{__MODULE__}.ep#{endpoint_id}.#{cluster_module.cluster_name()}"
            Supervisor.child_spec(
              {cluster_module, Keyword.merge(cluster_opts, name: name, endpoint: endpoint_id)},
              id: name
            )
          end)
        end)
      end

      # Convenience: read an attribute from a specific endpoint/cluster
      def read_attribute(endpoint_id, cluster_name, attribute_name) do
        name = :"#{__MODULE__}.ep#{endpoint_id}.#{cluster_name}"
        GenServer.call(name, {:read_attribute, attribute_name})
      end

      # Convenience: write an attribute
      def write_attribute(endpoint_id, cluster_name, attribute_name, value) do
        name = :"#{__MODULE__}.ep#{endpoint_id}.#{cluster_name}"
        GenServer.call(name, {:write_attribute, attribute_name, value})
      end

      # Convenience: invoke a command
      def invoke_command(endpoint_id, cluster_name, command_name, params \\ %{}) do
        name = :"#{__MODULE__}.ep#{endpoint_id}.#{cluster_name}"
        GenServer.call(name, {:invoke_command, command_name, params})
      end
    end
  end
end
```

### Usage in Application Supervisor

```elixir
# In your Nerves app
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Your Matter device — starts all endpoints and clusters
      MyApp.Light,

      # MatterEx handles BLE, commissioning, sessions, etc.
      {MatterEx, device: MyApp.Light, setup_pin: 20202021, discriminator: 3840}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### Device Supervision Tree

```
MatterEx.Device.Supervisor
├── MatterEx.CommissioningManager (GenStateMachine)
│   States: :uncommissioned → :commissioning → :commissioned
├── MatterEx.SessionManager
│   └── MatterEx.Session (per active session, DynamicSupervisor)
├── MatterEx.SubscriptionManager
├── MatterEx.Transport.Supervisor
│   ├── MatterEx.Transport.BLE (only during commissioning)
│   ├── MatterEx.Transport.UDP (operational, port 5540)
│   └── MatterEx.Transport.MDNS
└── MatterEx.Endpoint.Supervisor
    ├── MatterEx.Endpoint.0 (root)
    │   ├── MatterEx.Cluster.Descriptor
    │   └── MatterEx.Cluster.BasicInformation
    └── MatterEx.Endpoint.1 (application)
        ├── MatterEx.Cluster.OnOff
        └── MatterEx.Cluster.LevelControl
```

### Testing

- Device startup and supervision tree verification
- Cluster read/write/command handling
- Attribute change notifications to subscription manager
- Full integration test: simulated controller sends Read → gets correct Report

### Deliverable

Module `MatterEx.Device` + `MatterEx.Cluster` — the developer-facing API.

**Estimated effort**: 4-6 weeks.

---

## Integration Phase: Full Commissioning Flow

After all phases, the full commissioning flow works end-to-end:

```
Commissioner (phone/chip-tool)          Device (Elixir)
         │                                    │
         │     BLE: Discover (CHIPoBLE)       │
         │◄───────────────────────────────────│  MatterEx.Transport.BLE advertises
         │                                    │
         │     BLE: Connect                   │
         │───────────────────────────────────►│  MatterEx.Transport.BLE accepts
         │                                    │
         │     PASE: pbkdfParamRequest        │
         │───────────────────────────────────►│  MatterEx.Crypto.SPAKE2Plus
         │     PASE: pbkdfParamResponse       │
         │◄───────────────────────────────────│
         │     PASE: pake1 (pA)               │
         │───────────────────────────────────►│
         │     PASE: pake2 (pB)               │
         │◄───────────────────────────────────│
         │     PASE: pake3 (cA)               │
         │───────────────────────────────────►│
         │                                    │  Session established!
         │     Secure session established      │
         │                                    │
         │     IM: Write(WiFi credentials)     │
         │───────────────────────────────────►│  MatterEx.IM → VintageNet.configure
         │     IM: WriteResponse(success)      │
         │◄───────────────────────────────────│
         │                                    │  Device joins WiFi
         │     IM: InvokeCommand(CommArm)      │
         │───────────────────────────────────►│  MatterEx.CommissioningManager
         │                                    │
         │ ─ ─ BLE disconnects ─ ─ ─ ─ ─ ─ ─ │
         │                                    │
         │     mDNS: Discover on network       │
         │◄───────────────────────────────────│  mdns_lite
         │                                    │
         │     CASE: Sigma1/Sigma2/Sigma3      │
         │◄──────────────────────────────────►│  MatterEx.Crypto.CASE (over UDP)
         │                                    │
         │     Operational session established  │
         │                                    │
         │     IM: Read(OnOff)                 │
         │───────────────────────────────────►│  MatterEx.IM → MatterEx.Cluster.OnOff
         │     IM: ReportData(on=false)        │
         │◄───────────────────────────────────│
```

## Project Structure (Mono-repo)

Single `matter_ex` hex package with clear module boundaries:

```
matter_ex/
├── lib/
│   └── matter_ex/
│       ├── tlv.ex                    # TLV encoder/decoder (Phase 1)
│       ├── tlv/
│       │   ├── encoder.ex            # Binary encoding
│       │   ├── decoder.ex            # Binary decoding + streaming
│       │   └── types.ex              # Element type definitions
│       │
│       ├── transport/                # Transport layer (Phase 2)
│       │   ├── ble.ex               # CHIPoBLE via blue_heron/HCI
│       │   ├── btp.ex               # BLE Transport Protocol (fragmentation)
│       │   ├── udp.ex               # UDP transport (port 5540)
│       │   └── mdns.ex              # mDNS advertisement wrapper
│       │
│       ├── crypto/                   # Cryptography (Phase 3)
│       │   ├── spake2_plus.ex       # SPAKE2+ (PASE)
│       │   ├── certificate.ex       # X.509 / DAC handling (CASE)
│       │   ├── session_keys.ex      # AES-CCM encrypt/decrypt
│       │   └── kdf.ex              # HKDF, PBKDF2
│       │
│       ├── protocol/                 # Message layer (Phase 4)
│       │   ├── message.ex           # Message frame encode/decode
│       │   ├── mrp.ex              # Message Reliability Protocol
│       │   └── exchange.ex          # Exchange manager
│       │
│       ├── im/                       # Interaction Model (Phase 5)
│       │   ├── read.ex              # Read request/response
│       │   ├── write.ex             # Write request/response
│       │   ├── subscribe.ex         # Subscriptions + reports
│       │   ├── invoke.ex            # Command invocation
│       │   └── subscription_manager.ex
│       │
│       ├── device.ex                 # Device macro + supervisor (Phase 6)
│       ├── endpoint.ex               # Endpoint supervisor
│       ├── cluster.ex                # Cluster behaviour + macros
│       │
│       ├── clusters/                 # Built-in cluster implementations
│       │   ├── on_off.ex
│       │   ├── level_control.ex
│       │   ├── color_control.ex
│       │   ├── descriptor.ex
│       │   ├── basic_information.ex
│       │   ├── boolean_state.ex
│       │   ├── temperature_measurement.ex
│       │   └── ...                  # Easy to add more
│       │
│       ├── commissioning/            # Commissioning flow
│       │   ├── manager.ex           # GenStateMachine
│       │   ├── pase.ex              # PASE session establishment
│       │   └── case.ex              # CASE session establishment
│       │
│       └── session/                  # Session management
│           ├── manager.ex
│           └── session.ex
│
├── test/
│   └── matter_ex/
│       ├── tlv_test.exs
│       ├── tlv/
│       │   ├── encoder_test.exs
│       │   ├── decoder_test.exs
│       │   └── roundtrip_test.exs   # Property-based tests
│       ├── crypto/
│       │   ├── spake2_plus_test.exs # Test vectors from RFC 9383
│       │   └── session_keys_test.exs
│       ├── protocol/
│       │   ├── message_test.exs
│       │   └── mrp_test.exs
│       ├── cluster_test.exs         # Cluster macro tests
│       └── device_test.exs          # Full device integration
│
├── mix.exs
├── README.md
├── ELIXIR_MATTER_STACK.md           # This design document
└── config/
    └── config.exs
```

## Certification Considerations

The Connectivity Standards Alliance (CSA) certifies Matter implementations. Key points:

- **Test Harness**: The CSA provides a Python-based test harness (TH) for conformance testing. Our implementation would need to pass these tests.
- **Incremental certification**: You can certify for specific device types (e.g., "Dimmable Light"). You don't need to implement the entire spec.
- **Test events**: The CSA runs regular "test events" where implementations can be validated.
- **SDK is not required**: The CSA certifies the _product_, not the SDK. A non-C++ implementation is allowed as long as it passes the tests.
- **DAC (Device Attestation Certificate)**: For production, you need real certificates from the CSA. For development, test certificates work.

## Dependencies

| Package | Purpose | Status |
|---------|---------|--------|
| Erlang `:crypto` | All cryptographic operations | Ships with OTP |
| Erlang `:public_key` | X.509 certificate handling | Ships with OTP |
| `blue_heron` | BLE HCI access | Experimental, may need fork |
| `mdns_lite` | mDNS service advertisement | Mature, used in Nerves |
| `gen_state_machine` | Commissioning state machine | Mature |
| (none) | TLV, protocol, IM, data model | Pure Elixir |

## Comparison with Current Approach

| Aspect | Current (C++ NIF) | Elixir-First |
|--------|-------------------|--------------|
| BLE | BlueZ + D-Bus + custom Nerves system | blue_heron / HCI direct |
| Crash safety | NIF crash = BEAM crash | OTP supervision, graceful recovery |
| Data model | C++ codegen (ZAP) | Elixir behaviours, runtime configurable |
| Build time | ~30 min SDK build + cross-compile | `mix deps.get && mix compile` |
| Binary size | 225MB libCHIP.a + 111 .o files | ~1MB Elixir release |
| Testability | Hardware-dependent for most tests | Full test suite on host |
| Hot reload | Impossible (NIF reloading is unsafe) | Standard Elixir hot code reload |
| Certification | Inherits from SDK | Must pass test harness independently |
| Spec compliance | Battle-tested | New implementation, needs thorough testing |

## Timeline

| Phase | Duration | Cumulative |
|-------|----------|------------|
| 1. TLV | 2-3 weeks | 2-3 weeks |
| 2. BLE | 4-6 weeks | 6-9 weeks |
| 3. Crypto | 3-4 weeks | 9-13 weeks |
| 4. Protocol | 3-4 weeks | 12-17 weeks |
| 5. IM | 4-6 weeks | 16-23 weeks |
| 6. Device | 4-6 weeks | 20-29 weeks |
| Integration + testing | 4-6 weeks | 24-35 weeks |

Total: **6-9 months** for a working Elixir Matter device that can be commissioned and controlled.

## Getting Started

Phase 1 (TLV) is the foundation — every other layer depends on it. Start here:

```bash
# In the matter_ex directory
# 1. Create a new branch for the rewrite
git checkout -b elixir-native

# 2. The TLV module has zero external dependencies
#    Start by implementing lib/matter_ex/tlv.ex and tests

# 3. Validate against Matter SDK test vectors:
#    deps/connectedhomeip/src/lib/core/tests/TestCHIPTLV.cpp
```

## Remaining Open Questions

1. **blue_heron** — does it support GATT server role well enough for CHIPoBLE? Need to prototype in Phase 2.
2. **Versioning** — start at 0.1.0 since it's a new implementation
