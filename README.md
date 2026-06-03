# MatterEx

[![CI](https://github.com/TomHoenderdos/matter_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/TomHoenderdos/matter_ex/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/matter_ex.svg?cacheSeconds=300)](https://hex.pm/packages/matter_ex)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/matter_ex)

A [Matter](https://csa-iot.org/all-solutions/matter/) smart home protocol stack written in pure Elixir.

MatterEx implements the Matter application protocol from the ground up — TLV encoding,
secure sessions (PASE and CASE), the Interaction Model, mDNS discovery, and 60 clusters —
with zero external dependencies beyond OTP. It interoperates with
[chip-tool](https://github.com/project-chip/connectedhomeip/tree/master/examples/chip-tool),
the Matter reference controller, and Apple Home on iOS/macOS developer mode. The
test suite covers commissioning, read/write/invoke, subscriptions, wildcard reads,
and Apple-style chunked wildcard subscriptions.

> **Status**: Experimental. The protocol core works with chip-tool and Apple Home
> interop flows, but this is not yet production-ready. APIs may change.

## Features

- **Pure Elixir** — no C/C++ dependencies; all protocol logic in Elixir
- **Zero external deps** — only OTP's `:crypto` and `:public_key`
- **Controller interop** — commission with chip-tool and Apple Home, establish CASE sessions, read/write attributes, invoke commands, subscribe
- **Pure functional core** — PASE, CASE, and MessageHandler are stateless; GenServers are thin wrappers
- **1000+ unit tests** and 28 chip-tool integration tests
- **60 cluster implementations** covering lighting, HVAC, sensors, locks, media, and more

## Quick Start

Add MatterEx to your dependencies:

```elixir
def deps do
  [
    {:matter_ex, "~> 0.4.0"}
  ]
end
```

```elixir
# Define a device
defmodule MyApp.Light do
  use MatterEx.Device,
    vendor: :test,
    product: :smart_light

  endpoint :light, :dimmable_light
end
```

```elixir
# Start a Matter node
{:ok, _} = MyApp.Light.start_link()

MatterEx.Node.start_link(
  device: MyApp.Light,
  port: 5540,
  passcode: 20202021,
  discriminator: 3840
)
```

The node will advertise via mDNS and accept commissioning from any Matter controller.

Endpoint 0 is auto-generated with Descriptor, BasicInformation, GeneralCommissioning,
OperationalCredentials, AccessControl, NetworkCommissioning, and GroupKeyManagement.

## Hardware Example

`examples/net_test/` is a Nerves Raspberry Pi 4 example that exposes a dimmable
Matter light over IP, with BLE commissioning support. It includes Broadcom HCD
firmware loading, mDNS operational discovery, and the QR payload used for phone
commissioning tests.

```sh
cd examples/net_test
MIX_TARGET=rpi4 mix deps.get
MIX_TARGET=rpi4 mix firmware
MIX_TARGET=rpi4 mix upload
```

After boot, scan the generated setup QR with Apple Home or use chip-tool. The
example is intended for development and interop testing, not production devices.

## Automated Smoke Testing

Use `scripts/matter_smoke.exs` for a fast chip-tool based check that commissioning,
CASE, OnOff commands, and BasicInformation reads still work.

```sh
# Start an in-process MatterEx device and test it with chip-tool
mix run scripts/matter_smoke.exs

# Test an already-running device, for example examples/net_test on a Raspberry Pi
mix run scripts/matter_smoke.exs -- --mode remote --host 192.168.1.42
```

The remote mode uses `chip-tool pairing already-discovered`, so it does not depend
on mDNS discovery working from the test machine. Override defaults with flags such
as `--port 5540`, `--node-id 111`, `--passcode 20202021`, or
`--storage-directory /tmp/matter_ex_pi4_kvs`.

## Handling Incoming Commands

When a Matter controller (phone app, Alexa, Home Assistant, etc.) sends a command to
your device, the cluster's `handle_command/3` callback is invoked. This is where you
bridge Matter to your actual hardware or application logic:

```elixir
defmodule MyApp.Cluster.OnOff do
  use MatterEx.Cluster, :on_off

  command :on
  command :off
  command :toggle

  @impl MatterEx.Cluster
  def handle_command(:on, _params, state) do
    # Control your hardware here
    MyApp.GPIO.set_pin(17, :high)
    {:ok, nil, set_attribute(state, :on_off, true)}
  end

  def handle_command(:off, _params, state) do
    MyApp.GPIO.set_pin(17, :low)
    {:ok, nil, set_attribute(state, :on_off, false)}
  end

  def handle_command(:toggle, _params, state) do
    new_value = !get_attribute(state, :on_off)
    if new_value, do: MyApp.GPIO.set_pin(17, :high), else: MyApp.GPIO.set_pin(17, :low)
    {:ok, nil, set_attribute(state, :on_off, new_value)}
  end
end
```

Writable attributes (like `node_label`) can also be changed directly by controllers
via Matter write requests — the cluster GenServer handles this automatically.

Known cluster names can be listed from IEx:

```elixir
MatterEx.Cluster.known_clusters()
```

For example, `:on_off`, `:basic_information`, `:temperature_measurement`, and
`:door_lock` can be used directly with `use MatterEx.Cluster, name`.
Named built-in clusters infer their standard attributes automatically. Declare an
attribute only when you need to override defaults, writability, constraints, or
add a custom attribute.
Declare commands that your custom cluster module implements. Named commands like
`command :on` resolve the Matter command ID automatically, so raw IDs are only
needed for custom or vendor-specific commands.

Known endpoint device types can be listed the same way:

```elixir
MatterEx.DeviceTypes.known_device_types()
```

Named endpoint device types automatically add their required server clusters. Add
extra optional clusters only when your device needs them:

```elixir
endpoint :light, :on_off_light do
  cluster :level_control
end
```

Development vendor and product aliases are discoverable from IEx:

```elixir
MatterEx.Device.known_vendors()
MatterEx.Device.known_products()
```

Use raw Matter IDs only for custom or unsupported definitions. See
[`docs/advanced-matter-ids.md`](docs/advanced-matter-ids.md).

## Updating State from Your Application

When something changes on your device (a button press, a sensor reading), update the
Matter attribute so controllers see the new state.

Using the `MyApp.Light` from the Quick Start example above, here's a GenServer that
watches a GPIO button and pushes state into Matter:

```elixir
defmodule MyApp.ButtonWatcher do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(_opts) do
    :timer.send_interval(100, :check_button)
    {:ok, %{last_state: false}}
  end

  def handle_info(:check_button, state) do
    pressed = MyApp.GPIO.read_pin(4) == :high

    if pressed != state.last_state do
      # Update OnOff; subscribed controllers get notified.
      MyApp.Light.update_attribute(:light, :on_off, pressed)
    end

    {:noreply, %{state | last_state: pressed}}
  end
end
```

For a temperature sensor, first define the device:

```elixir
defmodule MyApp.Sensor do
  use MatterEx.Device,
    vendor: :test,
    product: :temperature_sensor

  endpoint :temperature, :temperature_sensor
end
```

Then push readings from your hardware:

```elixir
defmodule MyApp.TempPoller do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(_opts) do
    :timer.send_interval(5_000, :read_sensor)
    {:ok, %{}}
  end

  def handle_info(:read_sensor, state) do
    # Matter temperatures are in 0.01 C units (e.g., 2350 = 23.50 C)
    temp = MyApp.I2C.read_temperature() |> round()
    MyApp.Sensor.update_attribute(:temperature, :measured_value, temp)
    {:noreply, state}
  end
end
```

The Device API for reading and writing from Elixir:

```elixir
MyApp.Light.read_attribute(:light, :on_off)        # {:ok, true}
MyApp.Light.write_attribute(:light, :on_off, false) # :ok
MyApp.Light.update_attribute(:light, :on_off, true) # :ok
MyApp.Light.invoke(:light, :toggle)                 # {:ok, nil}
```

Use `update_attribute/3` or `update_attribute/4` for local device state changes,
including read-only Matter attributes such as sensor measurements. Use
`write_attribute/3` or `write_attribute/4` when you want to apply the same
writable-attribute rules that a Matter controller write request would use.

## Architecture

```
                         UDP / TCP
                            |
                         Node (GenServer)
                            |
                     MessageHandler (pure)
                       /          \
                 PASE (SPAKE2+)   CASE (Sigma)
                       \          /
                    ExchangeManager (MRP)
                            |
                      IM Router (pure)
                            |
                   Cluster GenServers
           (OnOff, Thermostat, DoorLock, ...)
```

- **Node** — binds UDP/TCP sockets, dispatches raw bytes
- **MessageHandler** — pure functional message orchestration; decrypts, routes to PASE/CASE/IM
- **PASE** — SPAKE2+ commissioning (passcode-based)
- **CASE** — certificate-authenticated session establishment (Sigma protocol)
- **ExchangeManager** — MRP reliability, retransmission, exchange tracking
- **IM Router** — dispatches Interaction Model operations to cluster GenServers
- **Clusters** — GenServers holding attribute state, handling commands

## Clusters

60 clusters organized by function:

**Lighting & Control** —
OnOff, LevelControl, ColorControl, FanControl, WindowCovering, PumpConfigurationAndControl

**Smart Home** —
DoorLock, Thermostat, Switch, ModeSelect, ValveConfigurationAndControl

**Sensors** —
TemperatureMeasurement, IlluminanceMeasurement, RelativeHumidityMeasurement,
PressureMeasurement, FlowMeasurement, OccupancySensing, ElectricalMeasurement

**Air Quality** —
AirQuality, ConcentrationMeasurement (CO2, PM2.5, PM10, TVOC), SmokeCOAlarm

**Infrastructure** —
Descriptor, BasicInformation, AccessControl, Binding, Groups, Scenes, Identify,
GeneralCommissioning, OperationalCredentials, NetworkCommissioning, GroupKeyManagement,
AdminCommissioning, PowerSource, BooleanState, BooleanStateConfiguration

**Diagnostics** —
GeneralDiagnostics, SoftwareDiagnostics, WiFiNetworkDiagnostics, EthernetNetworkDiagnostics

**Localization & Time** —
LocalizationConfiguration, TimeFormatLocalization, UnitLocalization, TimeSynchronization

**Labels** — FixedLabel, UserLabel

**OTA** — OTASoftwareUpdateProvider, OTASoftwareUpdateRequestor

**Energy** — DeviceEnergyManagement, EnergyPreference, PowerTopology

**Media** — MediaPlayback, ContentLauncher, AudioOutput

**Appliances** — LaundryWasherControls, DishwasherAlarm, RefrigeratorAlarm

**ICD** — ICDManagement

## Testing

Unit tests:

```bash
mix test
```

chip-tool integration tests (requires `chip-tool` in PATH):

```bash
mix run test_chip_tool.exs
```

The integration test commissions a device, then runs 28 steps: OnOff toggle/on/off,
BasicInformation reads, Descriptor validation, ACL reads, Identify invoke, Groups,
Scenes, timed interactions, wildcard reads, error paths, and subscriptions.

Apple Home compatibility is covered by regression tests for wildcard subscriptions,
chunked ReportData, SubscribeResponse completion, operational mDNS transition, ACL
writes, and fabric cleanup.

Re-run only previously failed tests:

```bash
mix run test_chip_tool.exs -- --retest
```

## Requirements

- Elixir ~> 1.17
- Erlang/OTP 26+
- No external dependencies

## License

Apache License 2.0 — see [LICENSE](LICENSE).
